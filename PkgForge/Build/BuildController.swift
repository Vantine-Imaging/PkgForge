// Copyright 2026 Vantine Imaging LLC
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Observation

/// The app's working state: the dropped bundle, the form, the log, the result.
@MainActor
@Observable
final class BuildController {

    enum Phase: Equatable {
        case empty
        case ready
        case building(fraction: Double, step: String)
        case finished(BuildOutcome)
        case failed(String)

        var isBuilding: Bool {
            if case .building = self { return true }
            return false
        }
    }

    // MARK: State

    private(set) var bundle: AppBundle?
    var configuration = PackageConfiguration()
    private(set) var signature: SignatureInfo?
    private(set) var stats: BundleStats?
    private(set) var isMeasuring = false
    private(set) var installerIdentities: [SigningIdentity] = []
    private(set) var log: [LogEntry] = []
    private(set) var phase: Phase = .empty
    private(set) var loadedProfileDate: Date?
    /// The version the saved profile was built at. The remembered Jamf display
    /// name was written for *that* version, so it is what has to be replaced
    /// when the name is carried forward to a new one.
    private(set) var loadedProfileVersion: String?

    /// Whether the named notarytool keychain profile actually resolves.
    enum NotaryProfileState: Equatable {
        case unchecked
        case checking
        case valid
        case invalid(String)
    }

    private(set) var notaryProfileState: NotaryProfileState = .unchecked

    /// Set when a bad drop needs explaining rather than silently ignoring (I-2).
    var inputError: String?
    /// Set when the output package already exists and needs a decision (B-11).
    var pendingOverwrite: URL?

    private let profiles: ProfileStore
    private let defaults: DefaultsStore
    private var buildTask: Task<Void, Never>?
    private var measureTask: Task<Void, Never>?

    init(profiles: ProfileStore, defaults: DefaultsStore) {
        self.profiles = profiles
        self.defaults = defaults
        Task { await refreshIdentities() }
    }

    // MARK: Derived

    var diagnostics: [ConfigurationDiagnostic] {
        guard let bundle else { return [] }
        return configuration.diagnostics(for: bundle) + signatureDiagnostics
    }

    /// Problems with the payload itself rather than the form. These are the
    /// ones that only surface minutes later, at the notary service or on the
    /// target Mac, so they belong in front of the operator now.
    private var signatureDiagnostics: [ConfigurationDiagnostic] {
        guard let signature else { return [] }
        var found: [ConfigurationDiagnostic] = []

        if signature.hasDebugEntitlement {
            found.append(.init(
                // Fatal only when it is certain to fail. Packaging a debug
                // build for a test Mac is a legitimate thing to do.
                severity: configuration.notarize ? .error : .warning,
                message: """
                    This is a debug build — it carries com.apple.security.get-task-allow,                     which lets any process attach a debugger to it. Apple's notary service                     rejects it outright, and it should not be deployed. Build for Release.
                    """
            ))
        }

        if configuration.notarize, signature.isSigned, !signature.hasHardenedRuntime {
            found.append(.init(
                severity: .error,
                message: "This app is signed without Hardened Runtime, which notarization requires."
            ))
        }

        return found
    }

    var blockingProblems: [ConfigurationDiagnostic] {
        diagnostics.filter { $0.severity == .error }
    }

    var canBuild: Bool {
        bundle != nil && blockingProblems.isEmpty && !phase.isBuilding
    }

    var outputURL: URL? {
        guard let bundle else { return nil }
        let name = PackageBuilder.packageFileName(for: bundle, version: configuration.version)
        return configuration.outputDirectory.appending(path: name)
    }

    var selectedIdentity: SigningIdentity? {
        guard let sha1 = configuration.signingIdentitySHA1 else { return nil }
        return installerIdentities.first { $0.sha1 == sha1 }
    }

    var finishedPackageURL: URL? {
        if case .finished(let outcome) = phase { return outcome.packageURL }
        return nil
    }

    // MARK: Input

    func refreshIdentities() async {
        installerIdentities = await SigningIdentityLoader.load()
        // A profile may name an identity that has since been removed.
        if let sha1 = configuration.signingIdentitySHA1,
           !installerIdentities.contains(where: { $0.sha1 == sha1 }) {
            configuration.signingIdentitySHA1 = nil
        }
    }

    /// Accepts a dropped or chosen URL. A replacement is accepted at any time
    /// and resets the form to the new bundle (I-4).
    func accept(url: URL) {
        inputError = nil
        do {
            let inspected = try BundleInspector.inspect(url: url)
            bundle = inspected
            applyConfiguration(for: inspected)
            log = [LogEntry(.info, "Loaded \(inspected.onDiskName).app — \(inspected.bundleIdentifier) \(inspected.preferredVersion)")]
            phase = .ready
            loadMetadata(for: inspected)
        } catch {
            bundle = nil
            signature = nil
            stats = nil
            phase = .empty
            inputError = error.localizedDescription
        }
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application, .applicationBundle]
        panel.prompt = "Choose"
        panel.message = "Choose an application bundle to package."
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            accept(url: url)
        }
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Where should the package be written?"
        panel.directoryURL = configuration.outputDirectory
        if panel.runModal() == .OK, let url = panel.url {
            configuration.outputDirectoryPath = url.path(percentEncoded: false)
        }
    }

    /// Checks the profile before a build rather than after a five-minute
    /// upload to Apple fails on a name typo.
    func verifyNotaryProfile() async {
        let profile = configuration.trimmedNotaryProfile
        guard !profile.isEmpty else {
            notaryProfileState = .invalid("Enter the profile name you used with notarytool store-credentials.")
            return
        }
        notaryProfileState = .checking
        do {
            let result = try await ProcessRunner.run(
                "/usr/bin/xcrun",
                ["notarytool", "history", "--keychain-profile", profile]
            )
            notaryProfileState = result.succeeded ? .valid : .invalid(result.message)
        } catch {
            notaryProfileState = .invalid(error.localizedDescription)
        }
    }

    func addExtraScriptFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose files to bundle into the package's Scripts directory."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = url.path(percentEncoded: false)
            if !configuration.extraScriptFiles.contains(path) {
                configuration.extraScriptFiles.append(path)
            }
        }
    }

    func removeExtraScriptFile(_ path: String) {
        configuration.extraScriptFiles.removeAll { $0 == path }
    }

    func clear() {
        buildTask?.cancel()
        measureTask?.cancel()
        bundle = nil
        signature = nil
        stats = nil
        loadedProfileDate = nil
        loadedProfileVersion = nil
        configuration = defaults.template
        log = []
        phase = .empty
        inputError = nil
    }

    /// Applies a saved profile if there is one, keeping only the version from
    /// the bundle in front of us (D-2).
    private func applyConfiguration(for bundle: AppBundle) {
        var next = defaults.configuration(for: bundle)
        if let profile = profiles.profile(for: bundle.bundleIdentifier) {
            next = profile.configuration
            // Read before it is overwritten: this is the previous version.
            loadedProfileVersion = profile.configuration.version
            next.version = bundle.preferredVersion
            loadedProfileDate = profile.savedAt
        } else {
            loadedProfileDate = nil
            loadedProfileVersion = nil
        }
        if let sha1 = next.signingIdentitySHA1,
           !installerIdentities.contains(where: { $0.sha1 == sha1 }) {
            next.signingIdentitySHA1 = nil
        }
        configuration = next
    }

    private func loadMetadata(for bundle: AppBundle) {
        signature = nil
        stats = nil
        isMeasuring = true

        measureTask?.cancel()
        measureTask = Task { [weak self] in
            async let signature = BundleInspector.signature(of: bundle.url)
            async let stats = Task.detached(priority: .utility) { BundleInspector.stats(of: bundle.url) }.value

            let (resolvedSignature, resolvedStats) = await (signature, stats)
            guard !Task.isCancelled else { return }
            guard let self, self.bundle == bundle else { return }
            self.signature = resolvedSignature
            self.stats = resolvedStats
            self.isMeasuring = false
        }
    }

    var savedJamfMetadata: JamfPackageMetadata? {
        guard let bundle else { return nil }
        return profiles.profile(for: bundle.bundleIdentifier)?.jamfMetadata
    }

    /// The version the remembered Jamf metadata was captured at.
    ///
    /// Deliberately not `configuration.version` from the profile: that moves on
    /// every successful build, while an upload happens less often, so using it
    /// silently compared a version against itself.
    var savedJamfMetadataVersion: String? {
        guard let bundle, let profile = profiles.profile(for: bundle.bundleIdentifier) else { return nil }
        if let recorded = profile.jamfMetadataVersion, !recorded.isEmpty {
            return recorded
        }
        // Profiles written before that was recorded: the remembered filename is
        // one PkgForge generated, so the version is still in it.
        guard let fileName = profile.jamfMetadata?.fileName else { return nil }
        return PackageBuilder.version(fromPackageFileName: fileName, bundle: bundle)
    }

    /// The record this app was last uploaded to, if any.
    var savedJamfPackageID: String? {
        guard let bundle else { return nil }
        return profiles.profile(for: bundle.bundleIdentifier)?.jamfPackageID
    }

    func rememberJamfMetadata(_ metadata: JamfPackageMetadata, packageID: String?) {
        guard let bundle else { return }
        profiles.recordJamfMetadata(
            metadata,
            version: configuration.version,
            packageID: packageID,
            for: bundle.bundleIdentifier
        )
    }

    // MARK: Building

    /// Entry point from the Build button. Stops for confirmation rather than
    /// overwriting a package that is already there (B-11).
    func startBuild() {
        guard let outputURL, canBuild else { return }
        if FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)) {
            pendingOverwrite = outputURL
        } else {
            performBuild()
        }
    }

    func confirmOverwrite() {
        pendingOverwrite = nil
        performBuild()
    }

    func cancelBuild() {
        buildTask?.cancel()
        buildTask = nil
        if phase.isBuilding {
            phase = .failed("Build cancelled.")
            append(LogEntry(.failure, "Build cancelled."))
        }
    }

    private func performBuild() {
        guard let bundle, let outputURL else { return }
        let request = BuildRequest(
            bundle: bundle,
            configuration: configuration,
            signingIdentitySHA1: selectedIdentity?.sha1,
            outputURL: outputURL,
            expectedFileCount: stats?.fileCount ?? 0
        )

        log = []
        phase = .building(fraction: 0.02, step: "Preparing")
        append(LogEntry(.info, "Building \(outputURL.lastPathComponent)"))
        if let identity = selectedIdentity {
            append(LogEntry(.info, "Signing with \(identity.name)"))
        } else {
            append(LogEntry(.warning, "Building unsigned — no installer identity selected."))
        }

        buildTask = Task { [weak self] in
            // The whole pipeline runs off the main actor so a multi-gigabyte
            // ditto does not freeze the window (B-7).
            let outcome: Result<BuildOutcome, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let result = try await PackageBuilder.build(
                        request,
                        log: { entry in Task { @MainActor in self?.append(entry) } },
                        progress: { fraction, step in
                            Task { @MainActor in self?.updateProgress(fraction, step) }
                        }
                    )
                    return .success(result)
                } catch {
                    return .failure(error)
                }
            }.value

            guard let self, !Task.isCancelled else { return }

            switch outcome {
            case .success(let result):
                self.append(LogEntry(.success, "Built \(result.packageURL.lastPathComponent)"))
                self.phase = .finished(result)
                // D-1 — remember the configuration that just worked.
                self.profiles.save(bundle: bundle, configuration: self.configuration)
            case .failure(let error):
                self.append(LogEntry(.failure, error.localizedDescription))
                self.phase = .failed(error.localizedDescription)
            }
            self.buildTask = nil
        }
    }

    private func updateProgress(_ fraction: Double, _ step: String) {
        guard phase.isBuilding else { return }
        phase = .building(fraction: fraction, step: step)
    }

    private func append(_ entry: LogEntry) {
        log.append(entry)
        if log.count > 4000 {
            log.removeFirst(log.count - 4000)
        }
    }

    // MARK: Finished-package actions

    func revealPackage() {
        guard let url = finishedPackageURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// B-12 — the command to verify the package on a test Mac.
    func copyInstallCommand() {
        guard let url = finishedPackageURL else { return }
        let command = "sudo installer -pkg \(ShellEscape.singleQuoted(url.path(percentEncoded: false))) -target / -verbose"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    func copyLog() {
        let text = log.map { "\($0.text)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Shows the generated scripts without building, so they can be reviewed.
    func previewScripts() -> (preinstall: String, postinstall: String)? {
        guard let bundle else { return nil }
        let generator = ScriptGenerator(bundle: bundle, configuration: configuration)
        return (generator.preinstall(), generator.postinstall())
    }
}
