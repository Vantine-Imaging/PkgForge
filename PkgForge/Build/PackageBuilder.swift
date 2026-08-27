// Copyright 2026 Vantine Imaging LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation

struct LogEntry: Identifiable, Sendable {
    enum Kind: Sendable { case info, command, output, warning, failure, success }

    let id = UUID()
    let date: Date
    let kind: Kind
    let text: String

    init(_ kind: Kind, _ text: String, date: Date = Date()) {
        self.kind = kind
        self.text = text
        self.date = date
    }
}

struct BuildRequest: Sendable {
    let bundle: AppBundle
    let configuration: PackageConfiguration
    /// SHA-1 fingerprint of the installer identity, or nil for an unsigned
    /// package. The fingerprint rather than the name: a team that has reissued
    /// its certificate has two with identical common names, and `codesign`
    /// refuses an ambiguous match.
    let signingIdentitySHA1: String?
    let outputURL: URL
    /// Regular files in the bundle, from the same walk that produced the size
    /// shown in the summary. Drives real copy progress; 0 means unknown.
    var expectedFileCount: Int = 0
}

/// Outcome of a notary submission.
struct NotarizationResult: Sendable, Equatable {
    let submissionID: String
    let status: String
}

/// Counts `ditto -V` progress lines across the reader's background queue.
private final class CopyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func add(_ n: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        count += n
        return count
    }
}

struct BuildOutcome: Sendable, Equatable {
    let packageURL: URL
    let byteCount: Int64
    let isSigned: Bool
}

enum BuildError: LocalizedError {
    case toolFailed(tool: String, status: Int32, output: String)
    case stagingFailed(String)
    case outputDirectoryUnwritable(String)
    case scriptSyntaxError(name: String, detail: String)
    case notarizationUnavailable
    case notarizationRejected(submissionID: String, status: String, detail: String)
    case notarizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .toolFailed(let tool, let status, let output):
            // Verbatim (B-8). `pkgbuild` explains itself perfectly well; a
            // generic "build failed" throws that explanation away.
            "\(tool) exited \(status).\n\n\(output)"
        case .stagingFailed(let detail):
            "Could not prepare the staging directory: \(detail)"
        case .outputDirectoryUnwritable(let path):
            "Cannot write to \(path)."
        case .notarizationUnavailable:
            """
            notarytool is not available. It ships with Xcode and the Command \
            Line Tools — install one of those, or turn notarization off.
            """
        case .notarizationRejected(let submissionID, let status, let detail):
            """
            Apple's notary service returned “\(status)” for submission \
            \(submissionID). The package is signed and on disk, but it is not \
            notarized.

            \(detail)
            """
        case .notarizationFailed(let detail):
            "Notarization could not be completed: \(detail)"
        case .scriptSyntaxError(let name, let detail):
            """
            The generated \(name) script is not valid bash, so the build was \
            stopped before it produced a package that would fail at install \
            time instead.

            \(detail)
            """
        }
    }
}

enum PackageBuilder {

    /// Sanitised so the filename cannot carry anything a shell would act on
    /// (N-3). The name is reduced to letters, digits, hyphen and underscore;
    /// the version additionally keeps dots, because turning `2.1.0` into
    /// `2-1-0` makes the package unrecognisable to everyone downstream for no
    /// safety gain — a dot is inert in a filename.
    static func packageFileName(for bundle: AppBundle, version: String) -> String {
        let name = sanitize(bundle.onDiskName)
        let cleanVersion = sanitize(version, keepingDots: true)
        if cleanVersion.isEmpty { return "\(name).pkg" }
        return "\(name)-\(cleanVersion).pkg"
    }

    private static func sanitize(_ value: String, keepingDots: Bool = false) -> String {
        let extra = keepingDots ? "-_." : "-_"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: extra))
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        // Collapse the runs the substitution creates, and trim the edges.
        var result = ""
        var lastWasDash = false
        for character in mapped {
            if character == "-" {
                if lastWasDash { continue }
                lastWasDash = true
            } else {
                lastWasDash = false
            }
            result.append(character)
        }
        // A leading dot would make the package a hidden file; `..` in a name
        // is a path traversal waiting to happen.
        return result
            .replacingOccurrences(of: "..", with: ".")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    }

    /// Runs the whole pipeline off the main actor (B-7).
    static func build(
        _ request: BuildRequest,
        log: @escaping @Sendable (LogEntry) -> Void,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> BuildOutcome {

        let fileManager = FileManager.default
        let bundle = request.bundle
        let configuration = request.configuration

        // B-1 — a fresh unique directory every time.
        let staging = fileManager.temporaryDirectory
            .appending(path: "PkgForge-\(UUID().uuidString)")
        let payload = staging.appending(path: "payload")
        let scripts = staging.appending(path: "scripts")

        // B-5 — removed on success and on every failure path.
        defer { try? fileManager.removeItem(at: staging) }

        // A cancelled or failed pkgbuild can leave a truncated file behind. Only
        // clean up something this build created — an existing package at that
        // path is the operator's, and they already confirmed overwriting it.
        let outputExisted = fileManager.fileExists(atPath: request.outputURL.path(percentEncoded: false))
        var completed = false
        defer {
            if !completed, !outputExisted {
                try? fileManager.removeItem(at: request.outputURL)
            }
        }

        do {
            try fileManager.createDirectory(at: payload, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: scripts, withIntermediateDirectories: true)
        } catch {
            throw BuildError.stagingFailed(error.localizedDescription)
        }

        let outputDirectory = request.outputURL.deletingLastPathComponent()
        if !fileManager.isWritableFile(atPath: outputDirectory.path(percentEncoded: false)) {
            try? fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            guard fileManager.isWritableFile(atPath: outputDirectory.path(percentEncoded: false)) else {
                throw BuildError.outputDirectoryUnwritable(outputDirectory.path(percentEncoded: false))
            }
        }

        log(LogEntry(.info, "Staging in \(staging.path(percentEncoded: false))"))

        // MARK: Copy the payload

        progress(0.1, "Copying \(bundle.onDiskName).app")
        let stagedApp = payload.appending(path: "\(bundle.onDiskName).app")

        // ditto, not FileManager.copyItem: extended attributes, resource forks
        // and symlinks all survive it intact (B-2).
        //
        // -V puts a line per file on stderr. Those aren't logged — a large app
        // would bury everything else — but counting them turns what used to be
        // a bar frozen at 10% for several minutes into real progress.
        let source = bundle.url.path(percentEncoded: false)
        let destination = stagedApp.path(percentEncoded: false)
        log(LogEntry(.command, "/usr/bin/ditto -V \(source) \(destination)"))

        let counter = CopyCounter()
        let expected = request.expectedFileCount
        let dittoResult = try await ProcessRunner.run("/usr/bin/ditto", ["-V", source, destination]) { chunk, _ in
            let copied = chunk.split(separator: "\n").reduce(into: 0) { total, line in
                if line.hasPrefix("copying file ") { total += 1 }
            }
            guard copied > 0 else { return }
            let done = counter.add(copied)
            if expected > 0 {
                let fraction = min(1.0, Double(done) / Double(expected))
                progress(0.1 + 0.35 * fraction, "Copying \(done.formatted()) of \(expected.formatted()) files")
            } else {
                progress(0.25, "Copying \(done.formatted()) files")
            }
        }
        guard dittoResult.succeeded else {
            throw BuildError.toolFailed(tool: "ditto", status: dittoResult.exitStatus, output: dittoResult.message)
        }
        log(LogEntry(.info, "Payload copied — \(counter.add(0).formatted()) files."))

        // MARK: Write the scripts

        progress(0.45, "Writing install scripts")
        let generator = ScriptGenerator(bundle: bundle, configuration: configuration)
        let preinstall = generator.preinstall()
        let postinstall = generator.postinstall()

        let preinstallURL = scripts.appending(path: "preinstall")
        let postinstallURL = scripts.appending(path: "postinstall")
        try writeScript(preinstall, to: preinstallURL)
        try writeScript(postinstall, to: postinstallURL)
        log(LogEntry(.info, "Wrote preinstall and postinstall (mode 755)."))

        if !configuration.extraScriptFiles.isEmpty {
            try bundleExtraFiles(configuration.extraScriptURLs, into: scripts, log: log)
        }

        // The operator can splice their own bash into either script. Catching a
        // syntax error here costs a second; catching it after deployment costs
        // a failed policy on every Mac in scope.
        try await checkSyntax(of: preinstallURL, name: "preinstall", log: log)
        try await checkSyntax(of: postinstallURL, name: "postinstall", log: log)

        // MARK: Build

        // MARK: Pin the install location

        progress(0.5, "Analysing bundle components")
        var componentPlist: URL?
        if configuration.preventRelocation {
            componentPlist = try await writeComponentPlist(payload: payload, staging: staging, log: log)
        }

        progress(0.55, "Running pkgbuild")
        var arguments = [
            "--root", payload.path(percentEncoded: false),
            "--install-location", configuration.installLocation,
            "--scripts", scripts.path(percentEncoded: false),
            "--identifier", configuration.identifier,
            "--version", configuration.version,
            // What lets this work without sudo (P-4, B-4): the installer
            // assigns correct ownership at install time regardless of who
            // owned the staged payload.
            "--ownership", "recommended",
        ]
        if let componentPlist {
            arguments += ["--component-plist", componentPlist.path(percentEncoded: false)]
        }
        if let identity = request.signingIdentitySHA1 {
            arguments += ["--sign", identity]
        }
        arguments.append(request.outputURL.path(percentEncoded: false))

        try await runTool("/usr/bin/pkgbuild", arguments, label: "pkgbuild", log: log)

        // MARK: Verify (B-9)

        progress(0.9, "Verifying package")
        await verify(request.outputURL, log: log)

        // MARK: Notarize (optional)

        // Set before notarizing on purpose: a notary rejection must not delete
        // the package. It is built, signed and on disk — just not notarized.
        completed = true

        if configuration.notarize {
            if request.signingIdentitySHA1 == nil {
                log(LogEntry(.warning, "Skipping notarization: an unsigned package cannot be notarized."))
            } else {
                progress(0.93, "Notarizing — Apple can take several minutes")
                let result = try await notarize(
                    request.outputURL,
                    profile: configuration.trimmedNotaryProfile,
                    log: log
                )
                log(LogEntry(.success, "Notarized and stapled (submission \(result.submissionID))."))
            }
        }

        let attributes = try? fileManager.attributesOfItem(atPath: request.outputURL.path(percentEncoded: false))
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        progress(1.0, "Done")

        return BuildOutcome(
            packageURL: request.outputURL,
            byteCount: size,
            isSigned: request.signingIdentitySHA1 != nil
        )
    }

    // MARK: - Helpers

    private static func writeScript(_ contents: String, to url: URL) throws {
        do {
            try Data(contents.utf8).write(to: url, options: .atomic)
            // Without the exec bit pkgbuild silently ignores the script: the
            // package builds, installs, and does nothing (B-3).
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
        } catch {
            throw BuildError.stagingFailed("writing \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Submits the package to Apple's notary service, waits for a verdict, and
    /// staples the ticket.
    ///
    /// Not needed for a package an MDM installs as root — that bypasses
    /// Gatekeeper entirely. It matters for the package someone double-clicks on
    /// a test Mac, which otherwise needs right-click-Open every time.
    private static func notarize(
        _ packageURL: URL,
        profile: String,
        log: @escaping @Sendable (LogEntry) -> Void
    ) async throws -> NotarizationResult {
        guard !profile.isEmpty else {
            throw BuildError.notarizationFailed(
                "No notarytool keychain profile is set. Create one with `xcrun notarytool store-credentials`, then name it in Settings."
            )
        }

        let path = packageURL.path(percentEncoded: false)
        log(LogEntry(.command, "/usr/bin/xcrun notarytool submit \(path) --keychain-profile \(profile) --wait"))
        log(LogEntry(.info, "Waiting on Apple. This usually takes a few minutes."))

        let submit: ProcessResult
        do {
            submit = try await ProcessRunner.run("/usr/bin/xcrun", [
                "notarytool", "submit", path,
                "--keychain-profile", profile,
                "--wait", "--timeout", "45m",
                "--no-progress",
                "--output-format", "json",
            ])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BuildError.notarizationUnavailable
        }

        struct Submission: Decodable {
            let id: String?
            let status: String?
            let message: String?
        }

        // A verdict comes back as JSON. A missing keychain profile, or no
        // notarytool at all, comes back as plain text on stderr instead.
        let parsed = submit.standardOutput
            .data(using: .utf8)
            .flatMap { try? JSONDecoder().decode(Submission.self, from: $0) }

        guard let parsed, let submissionID = parsed.id else {
            throw BuildError.notarizationFailed(submit.message)
        }

        let status = parsed.status ?? "Unknown"
        log(LogEntry(.info, "Notary status: \(status) (submission \(submissionID))"))

        guard status.caseInsensitiveCompare("Accepted") == .orderedSame else {
            // The verdict never says what was wrong. The log does.
            let detail = await notaryLog(submissionID: submissionID, profile: profile, log: log)
            throw BuildError.notarizationRejected(submissionID: submissionID, status: status, detail: detail)
        }

        log(LogEntry(.command, "/usr/bin/xcrun stapler staple \(path)"))
        let staple = try await ProcessRunner.run("/usr/bin/xcrun", ["stapler", "staple", path])
        guard staple.succeeded else {
            throw BuildError.notarizationFailed(
                "The ticket was issued but could not be stapled.\n\n\(staple.message)"
            )
        }

        if let validate = try? await ProcessRunner.run("/usr/bin/xcrun", ["stapler", "validate", path]),
           validate.succeeded {
            log(LogEntry(.info, "Stapled ticket validated."))
        }
        if let assess = try? await ProcessRunner.run(
            "/usr/sbin/spctl", ["--assess", "--type", "install", "-vv", path]
        ) {
            for line in assess.message.split(separator: "\n", omittingEmptySubsequences: true) {
                log(LogEntry(.output, String(line)))
            }
        }

        return NotarizationResult(submissionID: submissionID, status: status)
    }

    /// Fetches the notary log for a rejected submission. Best-effort: a failure
    /// here must not mask the rejection itself.
    private static func notaryLog(
        submissionID: String,
        profile: String,
        log: @escaping @Sendable (LogEntry) -> Void
    ) async -> String {
        log(LogEntry(.command, "/usr/bin/xcrun notarytool log \(submissionID) --keychain-profile \(profile)"))
        guard let result = try? await ProcessRunner.run("/usr/bin/xcrun", [
            "notarytool", "log", submissionID, "--keychain-profile", profile,
        ]) else {
            return "The notary log could not be fetched."
        }
        for line in result.standardOutput.split(separator: "\n", omittingEmptySubsequences: true).prefix(60) {
            log(LogEntry(.warning, String(line)))
        }
        return result.standardOutput.isEmpty ? result.message : result.standardOutput
    }

    /// Turns off bundle relocation for every component in the payload.
    ///
    /// Left alone, `pkgbuild` writes a `<relocate>` block into the package. At
    /// install time the installer then looks the bundle identifier up on the
    /// target Mac and, if it finds an existing copy somewhere other than the
    /// install location — `~/Applications`, `/Applications/Utilities`, an old
    /// copy on another volume — it puts the payload *there* instead.
    ///
    /// For a managed deployment that is never what was meant, and here it is
    /// actively harmful: the preinstall has already removed the app from the
    /// install location, and the postinstall then finds nothing at the path it
    /// expects and fails the policy while the payload sits somewhere else.
    private static func writeComponentPlist(
        payload: URL,
        staging: URL,
        log: @escaping @Sendable (LogEntry) -> Void
    ) async throws -> URL? {
        let url = staging.appending(path: "component.plist")

        let analyze = try await ProcessRunner.run(
            "/usr/bin/pkgbuild",
            ["--analyze", "--root", payload.path(percentEncoded: false), url.path(percentEncoded: false)]
        )
        guard analyze.succeeded,
              let data = try? Data(contentsOf: url),
              var components = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]],
              !components.isEmpty
        else {
            log(LogEntry(.warning, "Could not analyse bundle components; the package will use pkgbuild's defaults."))
            return nil
        }

        for index in components.indices {
            components[index]["BundleIsRelocatable"] = false
        }

        do {
            let updated = try PropertyListSerialization.data(
                fromPropertyList: components, format: .xml, options: 0
            )
            try updated.write(to: url, options: .atomic)
        } catch {
            log(LogEntry(.warning, "Could not rewrite the component plist: \(error.localizedDescription)"))
            return nil
        }

        let names = components.compactMap { $0["RootRelativeBundlePath"] as? String }
        log(LogEntry(.info, "Relocation disabled for \(names.count) component\(names.count == 1 ? "" : "s"): \(names.joined(separator: ", "))"))
        return url
    }

    /// Copies operator-supplied files into the Scripts directory. They are
    /// archived with the package but never invoked by macOS — only preinstall
    /// and postinstall are declared as script phases — so they exist purely for
    /// those two to call.
    private static func bundleExtraFiles(
        _ urls: [URL],
        into scripts: URL,
        log: @escaping @Sendable (LogEntry) -> Void
    ) throws {
        for url in urls {
            let name = url.lastPathComponent
            guard name != "preinstall", name != "postinstall" else {
                throw BuildError.stagingFailed("a bundled file named “\(name)” would replace the generated script")
            }
            let destination = scripts.appending(path: name)
            do {
                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                throw BuildError.stagingFailed("copying \(name): \(error.localizedDescription)")
            }

            // Executable only if it actually is one; a bundled plist or licence
            // file has no business carrying the exec bit.
            let handle = try? FileHandle(forReadingFrom: destination)
            let magic = (try? handle?.read(upToCount: 2)) ?? nil
            try? handle?.close()
            let mode = magic == Data("#!".utf8) ? 0o755 : 0o644
            try? FileManager.default.setAttributes(
                [.posixPermissions: mode],
                ofItemAtPath: destination.path(percentEncoded: false)
            )
            log(LogEntry(.info, "Bundled \(name) (mode \(String(mode, radix: 8)))."))
        }
    }

    private static func checkSyntax(
        of url: URL,
        name: String,
        log: @escaping @Sendable (LogEntry) -> Void
    ) async throws {
        let result = try await ProcessRunner.run("/bin/bash", ["-n", url.path(percentEncoded: false)])
        guard result.succeeded else {
            let detail = result.message.replacingOccurrences(
                of: url.path(percentEncoded: false),
                with: name
            )
            log(LogEntry(.failure, "\(name) failed `bash -n`."))
            throw BuildError.scriptSyntaxError(name: name, detail: detail)
        }
        log(LogEntry(.info, "\(name) passed `bash -n`."))
    }

    private static func runTool(
        _ path: String,
        _ arguments: [String],
        label: String,
        log: @escaping @Sendable (LogEntry) -> Void
    ) async throws {
        log(LogEntry(.command, ([path] + arguments).joined(separator: " ")))

        let result = try await ProcessRunner.run(path, arguments) { chunk, isError in
            for line in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
                log(LogEntry(isError ? .warning : .output, String(line)))
            }
        }

        guard result.succeeded else {
            throw BuildError.toolFailed(tool: label, status: result.exitStatus, output: result.message)
        }
    }

    /// Post-build checks. Never fatal — the package already exists, and what
    /// the operator wants here is a report (B-9).
    private static func verify(_ packageURL: URL, log: @escaping @Sendable (LogEntry) -> Void) async {
        let path = packageURL.path(percentEncoded: false)

        if let signature = try? await ProcessRunner.run("/usr/sbin/pkgutil", ["--check-signature", path]) {
            log(LogEntry(.command, "/usr/sbin/pkgutil --check-signature \(path)"))
            for line in signature.message.split(separator: "\n", omittingEmptySubsequences: true) {
                log(LogEntry(.output, String(line)))
            }
        }

        if let files = try? await ProcessRunner.run("/usr/sbin/pkgutil", ["--payload-files", path]) {
            let lines = files.standardOutput.split(separator: "\n", omittingEmptySubsequences: true)
            log(LogEntry(.command, "/usr/sbin/pkgutil --payload-files \(path)"))
            log(LogEntry(.info, "Payload contains \(lines.count) entries."))
            // A 4 GB app has six figures of payload entries; showing them all
            // turns the log view into a memory problem.
            for line in lines.prefix(50) {
                log(LogEntry(.output, String(line)))
            }
            if lines.count > 50 {
                log(LogEntry(.info, "…\(lines.count - 50) more entries not shown."))
            }
        }
    }
}
