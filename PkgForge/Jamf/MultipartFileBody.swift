import CryptoKit
import Foundation

/// Builds the `multipart/form-data` envelope for a package upload on disk
/// rather than in memory.
///
/// A 4 GB package assembled into a `Data` is a 4 GB resident allocation and
/// then some; `URLSession.upload(for:fromFile:)` streams from a file instead.
enum MultipartFileBody {

    struct Prepared: Sendable {
        let bodyURL: URL
        let boundary: String
        let totalBytes: Int64
        /// SHA-256 of the package itself, computed during the copy so the file
        /// is only read once.
        let sha256: String
    }

    enum MultipartError: LocalizedError {
        case cannotRead(String)
        case cannotWrite(String)

        var errorDescription: String? {
            switch self {
            case .cannotRead(let detail): "Could not read the package: \(detail)"
            case .cannotWrite(let detail): "Could not stage the upload: \(detail)"
            }
        }
    }

    private static let chunkSize = 4 * 1024 * 1024

    static func prepare(
        fileURL: URL,
        fieldName: String = "file",
        in directory: URL = FileManager.default.temporaryDirectory
    ) throws -> Prepared {
        let boundary = "PkgForge-\(UUID().uuidString)"
        let fileName = fileURL.lastPathComponent
        let bodyURL = directory.appending(path: "PkgForgeUpload-\(UUID().uuidString).multipart")

        // Built byte by byte rather than from a multi-line literal: CRLF is
        // required here and easy to lose to editors that trim line endings.
        var headerData = Data()
        headerData.append(Data("--\(boundary)\r\n".utf8))
        headerData.append(Data("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\r\n".utf8))
        headerData.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))

        let footerData = Data("\r\n--\(boundary)--\r\n".utf8)

        guard FileManager.default.createFile(atPath: bodyURL.path(percentEncoded: false), contents: nil) else {
            throw MultipartError.cannotWrite(bodyURL.lastPathComponent)
        }

        let input: FileHandle
        let output: FileHandle
        do {
            input = try FileHandle(forReadingFrom: fileURL)
            output = try FileHandle(forWritingTo: bodyURL)
        } catch {
            throw MultipartError.cannotRead(error.localizedDescription)
        }
        defer {
            try? input.close()
            try? output.close()
        }

        var digest = SHA256()
        var total = Int64(headerData.count + footerData.count)

        do {
            try output.write(contentsOf: headerData)
            while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
                digest.update(data: chunk)
                try output.write(contentsOf: chunk)
                total += Int64(chunk.count)
            }
            try output.write(contentsOf: footerData)
        } catch {
            try? FileManager.default.removeItem(at: bodyURL)
            throw MultipartError.cannotWrite(error.localizedDescription)
        }

        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        return Prepared(bodyURL: bodyURL, boundary: boundary, totalBytes: total, sha256: hash)
    }
}
