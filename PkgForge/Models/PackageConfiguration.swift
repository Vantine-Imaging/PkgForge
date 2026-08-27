// Copyright 2026 Vantine Imaging LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Everything the operator can set before a build (section 4), and everything
/// worth remembering between builds of the same app (D-1).
struct PackageConfiguration: Codable, Equatable, Sendable {
    var identifier: String = ""
    var version: String = ""
    var installLocation: String = "/Applications"
    var quitTimeout: Int = 30

    /// One absolute path per line. Tokens are expanded at generation time.
    var rootStalePaths: String = ""
    /// One path per line, relative to each home directory.
    var userStalePaths: String = PackageConfiguration.defaultUserStalePaths

    var removeStrayCopies: Bool = false
    var abortIfRunning: Bool = true
    /// Stops the installer redirecting the payload to wherever an existing
    /// copy of this bundle identifier happens to live.
    var preventRelocation: Bool = true

    /// SHA-1 of the chosen `Developer ID Installer` identity, or nil for an
    /// unsigned package.
    var signingIdentitySHA1: String?
    var outputDirectoryPath: String = PackageConfiguration.defaultOutputDirectory.path(percentEncoded: false)

    // MARK: Additional scripting

    /// Operator-supplied bash spliced into the generated preinstall.
    var customPreinstall: String = ""
    var customPreinstallPlacement: ScriptFragmentPlacement = .last
    /// Operator-supplied bash spliced into the generated postinstall, after
    /// ownership and permissions are corrected.
    var customPostinstall: String = ""
    /// Absolute paths to extra files bundled into the package's Scripts
    /// directory. macOS never runs these on its own — preinstall or
    /// postinstall has to call them.
    var extraScriptFiles: [String] = []

    // MARK: Notarization

    /// Submit the finished package to Apple's notary service and staple the
    /// ticket. Requires a signed package.
    var notarize: Bool = false
    /// `notarytool` keychain profile name, created once with
    /// `xcrun notarytool store-credentials`.
    var notaryProfile: String = ""

    // A saved profile is a long-lived on-disk format that will keep gaining
    // fields. Synthesised decoding throws on a missing key, and ProfileStore
    // decodes with `try?` — so one new field would silently erase every
    // profile the operator had. Decode each key independently instead.
    private enum CodingKeys: String, CodingKey {
        case identifier, version, installLocation, quitTimeout
        case rootStalePaths, userStalePaths
        case removeStrayCopies, abortIfRunning, preventRelocation
        case signingIdentitySHA1, outputDirectoryPath
        case customPreinstall, customPreinstallPlacement, customPostinstall, extraScriptFiles
        case notarize, notaryProfile
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = PackageConfiguration()

        func value<T: Decodable>(_ key: CodingKeys, _ default: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? `default`
        }

        identifier = value(.identifier, fallback.identifier)
        version = value(.version, fallback.version)
        installLocation = value(.installLocation, fallback.installLocation)
        quitTimeout = value(.quitTimeout, fallback.quitTimeout)
        rootStalePaths = value(.rootStalePaths, fallback.rootStalePaths)
        userStalePaths = value(.userStalePaths, fallback.userStalePaths)
        removeStrayCopies = value(.removeStrayCopies, fallback.removeStrayCopies)
        abortIfRunning = value(.abortIfRunning, fallback.abortIfRunning)
        preventRelocation = value(.preventRelocation, fallback.preventRelocation)
        signingIdentitySHA1 = try? container.decodeIfPresent(String.self, forKey: .signingIdentitySHA1)
        outputDirectoryPath = value(.outputDirectoryPath, fallback.outputDirectoryPath)
        customPreinstall = value(.customPreinstall, fallback.customPreinstall)
        customPreinstallPlacement = value(.customPreinstallPlacement, fallback.customPreinstallPlacement)
        customPostinstall = value(.customPostinstall, fallback.customPostinstall)
        extraScriptFiles = value(.extraScriptFiles, fallback.extraScriptFiles)
        notarize = value(.notarize, fallback.notarize)
        notaryProfile = value(.notaryProfile, fallback.notaryProfile)
    }

    static let defaultUserStalePaths = """
        Library/Caches/${BUNDLE_ID}
        Library/Saved Application State/${BUNDLE_ID}.savedState
        """

    static var defaultOutputDirectory: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// Form values for a freshly dropped bundle, before any saved profile is
    /// layered on top (C-1, C-2, C-3, C-4).
    static func defaults(for bundle: AppBundle) -> PackageConfiguration {
        var configuration = PackageConfiguration()
        configuration.identifier = bundle.bundleIdentifier
        configuration.version = bundle.preferredVersion
        return configuration
    }

    var outputDirectory: URL {
        URL(fileURLWithPath: outputDirectoryPath)
    }
}

/// Where an operator's own bash is spliced into the generated preinstall.
///
/// macOS runs exactly two scripts from a flat package — `preinstall` and
/// `postinstall`, as declared in its `PackageInfo`. The legacy `preflight`,
/// `postflight`, `preupgrade` and `postupgrade` phases belong to pre-10.5
/// bundle packages and are never invoked from a package `pkgbuild` produces.
/// So extra behaviour goes *inside* those two scripts, not beside them.
enum ScriptFragmentPlacement: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Runs first, once the console user has been resolved but before the app
    /// is asked to quit.
    case first
    /// Runs last, after the app is stopped and every stale path is gone.
    case last

    var id: String { rawValue }

    var label: String {
        switch self {
        case .first: "Before the app is stopped"
        case .last: "After cleanup, just before the script exits"
        }
    }
}

extension PackageConfiguration {

    var extraScriptURLs: [URL] {
        extraScriptFiles.map { URL(fileURLWithPath: $0) }
    }

    var hasCustomPreinstall: Bool {
        !customPreinstall.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasCustomPostinstall: Bool {
        !customPostinstall.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var trimmedNotaryProfile: String {
        notaryProfile.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Token expansion

extension PackageConfiguration {

    /// Substitutes `${BUNDLE_ID}` and `${APP_NAME}` (C-7). `APP_NAME` is the
    /// on-disk filename, matching what the scripts actually look for.
    static func expand(_ line: String, bundle: AppBundle, identifier: String) -> String {
        line
            .replacingOccurrences(of: "${BUNDLE_ID}", with: identifier)
            .replacingOccurrences(of: "${APP_NAME}", with: bundle.onDiskName)
    }

    private static func lines(_ text: String) -> [String] {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    func resolvedRootPaths(for bundle: AppBundle) -> [String] {
        Self.lines(rootStalePaths).map { Self.expand($0, bundle: bundle, identifier: identifier) }
    }

    func resolvedUserPaths(for bundle: AppBundle) -> [String] {
        Self.lines(userStalePaths)
            .map { Self.expand($0, bundle: bundle, identifier: identifier) }
            // Per-user entries are relative to a home directory; a leading
            // slash here would escape it.
            .map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
    }
}

// MARK: - Validation

/// A non-blocking observation about the current form (C-12, C-13), or a hard
/// error that stops the build.
struct ConfigurationDiagnostic: Identifiable, Hashable, Sendable {
    enum Severity: Sendable { case warning, error }

    let id = UUID()
    let severity: Severity
    let message: String
}

extension PackageConfiguration {

    /// Root paths that would delete something structural. Deleting a bare
    /// `/Library` on every install is not a cleanup, it is an outage.
    private static let dangerousRoots: Set<String> = [
        "/", "/Applications", "/Library", "/Users", "/System", "/private", "/var", "/usr", "/opt", "/etc"
    ]

    func diagnostics(for bundle: AppBundle) -> [ConfigurationDiagnostic] {
        var found: [ConfigurationDiagnostic] = []

        if identifier.trimmingCharacters(in: .whitespaces).isEmpty {
            found.append(.init(severity: .error, message: "Package identifier is required."))
        }
        if version.trimmingCharacters(in: .whitespaces).isEmpty {
            found.append(.init(severity: .error, message: "Version is required."))
        }
        if !installLocation.hasPrefix("/") {
            found.append(.init(severity: .error, message: "Install location must be an absolute path."))
        }
        if quitTimeout < 0 {
            found.append(.init(severity: .error, message: "Quit timeout cannot be negative."))
        }

        for path in resolvedRootPaths(for: bundle) {
            let normalized = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path

            if !normalized.hasPrefix("/") {
                found.append(.init(
                    severity: .error,
                    message: "Root-level path “\(path)” is not absolute. Per-user paths belong in the field below."
                ))
                continue
            }
            if Self.dangerousRoots.contains(normalized) {
                found.append(.init(
                    severity: .warning,
                    message: "“\(normalized)” would be deleted whole on every install. Almost certainly not what you want."
                ))
            }
            if normalized.contains("*") || normalized.contains("?") {
                found.append(.init(
                    severity: .warning,
                    message: "“\(normalized)” contains a wildcard. It is deleted as a literal path, not expanded."
                ))
            }
        }

        var seenNames: Set<String> = []
        for path in extraScriptFiles {
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent

            if name == "preinstall" || name == "postinstall" {
                found.append(.init(
                    severity: .error,
                    message: "“\(name)” would overwrite the script PkgForge generates. Rename the file."
                ))
            }
            if !seenNames.insert(name).inserted {
                found.append(.init(
                    severity: .error,
                    message: "Two bundled files are both named “\(name)”. Only one can be included."
                ))
            }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            if !exists {
                found.append(.init(severity: .error, message: "Bundled file “\(name)” is no longer at \(path)."))
            } else if isDirectory.boolValue {
                found.append(.init(severity: .error, message: "“\(name)” is a folder. Only files can be bundled."))
            }
        }

        for path in resolvedUserPaths(for: bundle) {
            if path.hasPrefix("Library/Preferences") {
                found.append(.init(
                    severity: .warning,
                    message: "“\(path)” wipes user settings on every upgrade. Occasionally intended, usually not."
                ))
            }
            if path.contains("*") || path.contains("?") {
                found.append(.init(
                    severity: .warning,
                    message: "“\(path)” contains a wildcard. It is deleted as a literal path, not expanded."
                ))
            }
        }

        return found
    }

    var hasBlockingProblem: Bool { false }
}
