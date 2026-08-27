// Copyright 2026 Vantine Imaging LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// A remembered configuration for one app (D-1).
///
/// The cleanup path lists are the only part of a package that takes real
/// thought, and they do not change between versions of an app. Persisting them
/// is what makes the second build of the same app a two-click operation.
struct BuildProfile: Codable, Identifiable, Sendable, Equatable {
    var id: String { bundleIdentifier }

    var bundleIdentifier: String
    var appName: String
    var savedAt: Date
    var configuration: PackageConfiguration
    /// Jamf Pro package metadata from the last upload of this app.
    var jamfMetadata: JamfPackageMetadata?
    /// The Jamf Pro package record this app was last uploaded to. Lets a new
    /// version offer to replace that record — the record's own name and
    /// filename change with each version, so nothing else identifies it.
    var jamfPackageID: String?
    /// The app version that metadata was captured at. Not the same as
    /// `configuration.version`, which moves on every successful build — an
    /// upload happens less often than a build, and the remembered display name
    /// belongs to whichever version was last *uploaded*.
    var jamfMetadataVersion: String?
}

@MainActor
@Observable
final class ProfileStore {

    private(set) var profiles: [BuildProfile] = []
    private(set) var lastError: String?

    private let directory: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "PkgForge/Profiles")
        self.directory = base
        reload()
    }

    var directoryPath: String { directory.path(percentEncoded: false) }

    func reload() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []

        profiles = contents
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(BuildProfile.self, from: data)
            }
            .sorted { $0.savedAt > $1.savedAt }
    }

    func profile(for bundleIdentifier: String) -> BuildProfile? {
        profiles.first { $0.bundleIdentifier == bundleIdentifier }
    }

    /// Saves after a successful build. The version is stored with the rest but
    /// is deliberately ignored on load — the new bundle is the authority on
    /// which version this is (D-2).
    func save(
        bundle: AppBundle,
        configuration: PackageConfiguration,
        jamfMetadata: JamfPackageMetadata? = nil
    ) {
        let existing = profile(for: bundle.bundleIdentifier)
        let profile = BuildProfile(
            bundleIdentifier: bundle.bundleIdentifier,
            appName: bundle.displayName,
            savedAt: Date(),
            configuration: configuration,
            jamfMetadata: jamfMetadata ?? existing?.jamfMetadata,
            jamfPackageID: existing?.jamfPackageID,
            jamfMetadataVersion: existing?.jamfMetadataVersion
        )
        write(profile)
    }

    func recordJamfMetadata(
        _ metadata: JamfPackageMetadata,
        version: String,
        packageID: String?,
        for bundleIdentifier: String
    ) {
        guard var profile = profile(for: bundleIdentifier) else { return }
        profile.jamfMetadata = metadata
        profile.jamfMetadataVersion = version
        profile.jamfPackageID = packageID ?? profile.jamfPackageID
        profile.savedAt = Date()
        write(profile)
    }

    func delete(_ profile: BuildProfile) {
        try? FileManager.default.removeItem(at: fileURL(for: profile.bundleIdentifier))
        profiles.removeAll { $0.bundleIdentifier == profile.bundleIdentifier }
    }

    private func write(_ profile: BuildProfile) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(profile).write(to: fileURL(for: profile.bundleIdentifier), options: .atomic)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            return
        }

        if let index = profiles.firstIndex(where: { $0.bundleIdentifier == profile.bundleIdentifier }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        profiles.sort { $0.savedAt > $1.savedAt }
    }

    /// Bundle identifiers are almost always filename-safe, but nothing
    /// guarantees it — a `/` in one would write outside the profiles folder.
    private func fileURL(for bundleIdentifier: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let safe = String(bundleIdentifier.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return directory.appending(path: "\(safe.isEmpty ? "unnamed" : safe).json")
    }
}
