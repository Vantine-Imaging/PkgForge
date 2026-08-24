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
    /// Set when a record with the same filename already exists on the server.
    private(set) var duplicate: JamfPackageSummary?
    /// When true, the existing record is updated instead of a new one created.
    var replaceExisting = true

    private(set) var packageURL: URL?
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

    func prepare(for packageURL: URL, bundle: AppBundle?, configuration: PackageConfiguration?, remembered: JamfPackageMetadata?) {
        self.packageURL = packageURL
        var starting = remembered ?? JamfPackageMetadata()
        starting.fileName = packageURL.lastPathComponent
        if starting.displayName.isEmpty || remembered == nil {
            if let bundle, let configuration {
                starting.displayName = "\(bundle.displayName) \(configuration.version)"
            } else {
                starting.displayName = packageURL.deletingPathExtension().lastPathComponent
            }
        }
        metadata = starting
        phase = .editing
        duplicate = nil
    }

    /// Looks for a same-named package before offering to upload, so a repeat
    /// build does not silently become a second record.
    func checkForDuplicate(using client: JamfClient) async {
        phase = .checkingForDuplicate
        do {
            duplicate = try await client.existingPackage(fileName: metadata.fileName)
        } catch {
            duplicate = nil
        }
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

        do {
            let packageID: String
            if let duplicate, replaceExisting {
                try await client.updatePackage(id: duplicate.id, metadata: metadata, sha256: prepared.sha256)
                packageID = duplicate.id
            } else {
                packageID = try await client.createPackage(metadata, sha256: prepared.sha256)
                createdPackageID = packageID
            }

            phase = .uploading(sent: 0, total: prepared.totalBytes)
            try await client.uploadPackageFile(packageID: packageID, multipart: prepared) { [weak self] sent, total in
                Task { @MainActor in
                    guard let self, self.isBusy else { return }
                    self.phase = .uploading(sent: sent, total: total > 0 ? total : prepared.totalBytes)
                }
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

    func reset() {
        phase = .editing
    }
}
