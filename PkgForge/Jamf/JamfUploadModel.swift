// Copyright 2026 Vantine Imaging LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// Drives one package upload: metadata, duplicate handling, progress.
@MainActor
@Observable
final class JamfUploadModel {

    enum Phase: Equatable {
        case editing
        case checkingForDuplicate
        case preparing
        case uploading(sent: Int64, total: Int64)
        case finished(packageID: String)
        case failed(String)
    }

    var metadata = JamfPackageMetadata()
    private(set) var phase: Phase = .editing
    /// Set when a record on the server collides with this upload — same
    /// filename, or the same display name Jamf requires to be unique.
    private(set) var duplicate: JamfPackageSummary?
    /// The record this app was last uploaded to. A new version collides with
    /// nothing, so without this there is no way to offer to reuse it — and
    /// repointing one record at each new version is a perfectly normal way to
    /// run Jamf, since policies then need no editing.
    private(set) var previousUpload: JamfPackageSummary?
    /// The record an upload will write to when replacing, whichever applies.
    var replaceTarget: JamfPackageSummary? { duplicate ?? previousUpload }
    /// When true, the existing record is updated instead of a new one created.
    /// Set by `checkForDuplicate` once it knows which case applies.
    var replaceExisting = true

    /// True when the existing record shares this upload's display name. Jamf Pro
    /// will not accept a second record with the same name, so "create a new
    /// record" is not an option until the name is changed.
    var duplicatesDisplayName: Bool {
        guard let duplicate else { return false }
        return duplicate.packageName == metadata.displayName
    }

    /// True when the only candidate is the record from a previous version, so
    /// replacing means repointing it rather than overwriting a clash.
    var replacingPreviousVersion: Bool {
        duplicate == nil && previousUpload != nil
    }

    /// True when a record matched but points at a different file — replacing it
    /// repoints it at this package.
    var duplicatePointsElsewhere: Bool {
        guard let target = replaceTarget else { return false }
        return target.fileName != metadata.fileName
    }

    var canUpload: Bool {
        guard !metadata.displayName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if duplicatesDisplayName && !replaceExisting { return false }
        return true
    }

    private(set) var packageURL: URL?
    /// Set when the file uploaded but something non-essential did not, e.g. the
    /// metadata update on a replaced record.
    private(set) var warning: String?
    /// Set while an upload is in flight so it can be called off.
    private var uploadTask: Task<Void, Never>?

    var isBusy: Bool {
        switch phase {
        case .editing, .finished, .failed: false
        default: true
        }
    }

    var progressFraction: Double? {
        guard case .uploading(let sent, let total) = phase, total > 0 else { return nil }
        return Double(sent) / Double(total)
    }

    var progressDescription: String? {
        guard case .uploading(let sent, let total) = phase else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: sent)) of \(formatter.string(fromByteCount: total))"
    }

    func prepare(
        for packageURL: URL,
        bundle: AppBundle?,
        configuration: PackageConfiguration?,
        remembered: JamfPackageMetadata?,
        previousVersion: String? = nil
    ) {
        self.packageURL = packageURL
        var starting = remembered ?? JamfPackageMetadata()
        starting.fileName = packageURL.lastPathComponent

        if starting.displayName.isEmpty || remembered == nil {
            if let bundle, let configuration {
                starting.displayName = "\(bundle.displayName) \(configuration.version)"
            } else {
                starting.displayName = packageURL.deletingPathExtension().lastPathComponent
            }
        } else {
            // The filename was refreshed above; the display name has to follow,
            // or a new version uploads into a record still named for the old one.
            starting.displayName = Self.reversioned(
                starting.displayName,
                appName: bundle?.displayName,
                from: previousVersion,
                to: configuration?.version
            )
        }

        metadata = starting
        phase = .editing
        duplicate = nil
    }

    /// Carries a remembered display name forward to a new version.
    ///
    /// The name belongs to the operator — it may be "Thea 2.13.1", or
    /// "Thea 2.13.1 (Photo Team)", or something with no version in it at all.
    /// Regenerating it outright would throw away a deliberate rename; leaving it
    /// alone shipped 2.13.2 into a record still called "Thea 2.13.1".
    ///
    /// So: when the name is exactly what PkgForge generated last time, it is
    /// regenerated. Otherwise the version is substituted only where it stands as
    /// its own token, which leaves a version that happens to be a substring of a
    /// word — an app called "Studio 3" — intact.
    static func reversioned(
        _ displayName: String,
        appName: String?,
        from old: String?,
        to new: String?
    ) -> String {
        guard let old, let new, !old.isEmpty, !new.isEmpty, old != new else { return displayName }

        if let appName, displayName == "\(appName) \(old)" {
            return "\(appName) \(new)"
        }

        var result = ""
        var cursor = displayName.startIndex
        while let match = displayName.range(of: old, range: cursor..<displayName.endIndex) {
            let isWord: (Character) -> Bool = { $0.isLetter || $0.isNumber }
            let precededByWord = match.lowerBound > displayName.startIndex
                && isWord(displayName[displayName.index(before: match.lowerBound)])
            let followedByWord = match.upperBound < displayName.endIndex
                && isWord(displayName[match.upperBound])

            result += displayName[cursor..<match.lowerBound]
            result += (precededByWord || followedByWord) ? old : new
            cursor = match.upperBound
        }
        result += displayName[cursor...]
        return result
    }

    /// Looks for a same-named package before offering to upload, so a repeat
    /// build does not silently become a second record.
    func checkForDuplicate(
        using client: JamfClient,
        previousPackageID: String? = nil,
        previousMetadata: JamfPackageMetadata? = nil
    ) async {
        phase = .checkingForDuplicate
        do {
            duplicate = try await client.existingPackage(
                fileName: metadata.fileName,
                packageName: metadata.displayName
            )
        } catch {
            duplicate = nil
        }

        // Only look for the previous record when nothing collides: a collision is
        // the stronger signal and already provides a replace target.
        previousUpload = nil
        if duplicate == nil {
            if let previousPackageID {
                previousUpload = try? await client.package(id: previousPackageID)
            } else if let previousMetadata {
                // Profiles written before the record id was stored: the previous
                // upload's own filename and display name still identify it.
                previousUpload = try? await client.existingPackage(
                    fileName: previousMetadata.fileName,
                    packageName: previousMetadata.displayName
                )
            }
        }

        // A collision defaults to replacing, because creating a second record is
        // what the server refuses. Repointing a previous version's record
        // defaults to off: it is the destructive option of the two, and adding a
        // record is what most Jamf setups expect for a new version.
        replaceExisting = duplicate != nil

        phase = .editing
    }

    func upload(using client: JamfClient) async {
        guard let packageURL else { return }
        let task = Task { await performUpload(of: packageURL, using: client) }
        uploadTask = task
        await task.value
        uploadTask = nil
    }

    /// Stops an upload in flight. The staged body is cleaned up and any record
    /// this attempt created is removed again.
    func cancel() {
        uploadTask?.cancel()
    }

    private func performUpload(of packageURL: URL, using client: JamfClient) async {
        phase = .preparing
        let prepared: MultipartFileBody.Prepared
        do {
            prepared = try MultipartFileBody.prepare(fileURL: packageURL)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        defer { try? FileManager.default.removeItem(at: prepared.bodyURL) }

        guard !Task.isCancelled else {
            phase = .editing
            return
        }

        // Tracked separately from `duplicate`: only a record this attempt
        // created should be cleaned up if the upload then fails. An existing
        // record belongs to the operator whether or not this upload works.
        var createdPackageID: String?

        warning = nil

        do {
            let packageID: String
            if let target = replaceTarget, replaceExisting {
                packageID = target.id
                // Best-effort: getting the new file onto the distribution point
                // is the point of this operation, and a rejected metadata
                // change should not stand in the way of it. Reported, not
                // swallowed.
                do {
                    try await client.updatePackage(id: packageID, metadata: metadata, sha256: prepared.sha256)
                } catch {
                    warning = "The package record's details were not updated — \(error.localizedDescription)"
                }
            } else {
                do {
                    packageID = try await client.createPackage(metadata, sha256: prepared.sha256)
                } catch {
                    throw JamfError.step("creating the package record", underlying: error)
                }
                createdPackageID = packageID
            }

            phase = .uploading(sent: 0, total: prepared.totalBytes)
            do {
                try await client.uploadPackageFile(packageID: packageID, multipart: prepared) { [weak self] sent, total in
                    Task { @MainActor in
                        guard let self, self.isBusy else { return }
                        self.phase = .uploading(sent: sent, total: total > 0 ? total : prepared.totalBytes)
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw JamfError.step("uploading the file", underlying: error)
            }

            phase = .finished(packageID: packageID)
        } catch is CancellationError {
            await rollBack(createdPackageID, using: client, reason: "Upload cancelled.")
        } catch let error as URLError where error.code == .cancelled {
            await rollBack(createdPackageID, using: client, reason: "Upload cancelled.")
        } catch {
            await rollBack(createdPackageID, using: client, reason: error.localizedDescription)
        }
    }

    /// A package record with no file behind it shows up in Jamf as a usable
    /// package and fails every policy that scopes it, so it is worse than
    /// nothing. Removed on the way out.
    private func rollBack(_ packageID: String?, using client: JamfClient, reason: String) async {
        guard let packageID else {
            phase = .failed(reason)
            return
        }
        do {
            try await client.deletePackage(id: packageID)
            phase = .failed("\(reason)\n\nThe empty package record this created (id \(packageID)) was removed again.")
        } catch {
            phase = .failed("\(reason)\n\nAn empty package record was left behind in Jamf Pro (id \(packageID)) and could not be removed automatically — delete it by hand.")
        }
    }

    #if DEBUG
    /// Test seam: the real path resolves these from the server.
    func setForTesting(duplicate: JamfPackageSummary?, previousUpload: JamfPackageSummary?) {
        self.duplicate = duplicate
        self.previousUpload = previousUpload
    }

    /// Mirrors what `checkForDuplicate` does once it knows the case.
    func applyDefaultForTesting() {
        replaceExisting = duplicate != nil
    }
    #endif

    func reset() {
        phase = .editing
    }
}
