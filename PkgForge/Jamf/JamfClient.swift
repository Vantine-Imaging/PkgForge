import Foundation

enum JamfError: LocalizedError {
    case invalidServerURL
    case authenticationFailed(String)
    case httpError(statusCode: Int, body: String)
    case decodingFailed(String)
    case uploadUnsupported(String)
    /// Wraps another error with the step it happened in, so a 400 is
    /// attributable to creating the record, updating it, or the upload itself.
    case step(String, underlying: any Error)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            "That is not a valid Jamf Pro URL. Use the full https:// address."
        case .authenticationFailed(let detail):
            "Authentication failed: \(detail)"
        case .httpError(let statusCode, let body):
            // Verbatim and untruncated: for a 400 the `errors` array names the
            // offending field, and that is the only useful thing in the whole
            // response.
            "Jamf Pro returned HTTP \(statusCode).\n\n\(body)"
        case .decodingFailed(let detail):
            "Could not read the server response: \(detail)"
        case .step(let step, let underlying):
            "While \(step): \(underlying.localizedDescription)"
        case .uploadUnsupported(let version):
            """
            This Jamf Pro (\(version)) does not offer the package upload \
            endpoint. Uploading through the API needs Jamf Pro 11.5 or later \
            with a cloud distribution point.
            """
        }
    }
}

struct JamfCategory: Identifiable, Hashable, Sendable, Decodable {
    let id: String
    let name: String
}

struct JamfPackageSummary: Identifiable, Hashable, Sendable, Decodable {
    let id: String
    let packageName: String
    let fileName: String
}

/// The metadata written to the Jamf Pro package record.
struct JamfPackageMetadata: Codable, Equatable, Sendable {
    var displayName: String = ""
    var fileName: String = ""
    var categoryID: String = "-1"
    var info: String = ""
    var notes: String = ""
    var priority: Int = 10
    var rebootRequired: Bool = false
    var osRequirements: String = ""
    var fillUserTemplate: Bool = false
    var suppressUpdates: Bool = false
    var suppressFromDock: Bool = false
    var suppressEula: Bool = false
    var suppressRegistration: Bool = false

    func requestBody(sha256: String?) -> [String: Any] {
        var body: [String: Any] = [
            "packageName": displayName,
            "fileName": fileName,
            "categoryId": categoryID.isEmpty ? "-1" : categoryID,
            "info": info,
            "notes": notes,
            "priority": priority,
            "osRequirements": osRequirements,
            "fillUserTemplate": fillUserTemplate,
            "indexed": false,
            "fillExistingUsers": false,
            "swu": false,
            "rebootRequired": rebootRequired,
            "osInstall": false,
            "suppressUpdates": suppressUpdates,
            "suppressFromDock": suppressFromDock,
            "suppressEula": suppressEula,
            "suppressRegistration": suppressRegistration,
        ]
        if let sha256, !sha256.isEmpty {
            body["hashType"] = "SHA_256"
            body["hashValue"] = sha256
        }
        return body
    }
}

/// Forwards upload progress off the URLSession delegate queue.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Int64, Int64) -> Void

    init(onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        onProgress(totalBytesSent, totalBytesExpectedToSend)
    }
}

/// Async client for one Jamf Pro server.
actor JamfClient {
    let server: JamfServer
    private let baseURL: URL
    private let secret: String
    private let session: URLSession

    private var token: String?
    private var tokenExpiry: Date = .distantPast

    init(server: JamfServer, secret: String) throws {
        guard let url = server.url else { throw JamfError.invalidServerURL }
        self.server = server
        self.baseURL = url
        self.secret = secret

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        // A multi-gigabyte package over a slow uplink is a long-lived task.
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Auth

    private struct OAuthToken: Decodable {
        let accessToken: String
        let expiresIn: Double

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
        }
    }

    private struct AccountToken: Decodable {
        let token: String
        let expires: String?
    }

    private func validToken() async throws -> String {
        if let token, tokenExpiry.timeIntervalSinceNow > 30 {
            return token
        }

        var request: URLRequest
        switch server.authMode {
        case .apiClient:
            request = URLRequest(url: baseURL.appending(path: "api/oauth/token"))
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formEncoded([
                "grant_type": "client_credentials",
                "client_id": server.account,
                "client_secret": secret,
            ])
        case .account:
            request = URLRequest(url: baseURL.appending(path: "api/v1/auth/token"))
            request.httpMethod = "POST"
            let credentials = Data("\(server.account):\(secret)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw JamfError.authenticationFailed("No HTTP response from \(server.host).")
        }
        guard http.statusCode == 200 else {
            let body = String(decoding: data, as: UTF8.self)
            let hint = http.statusCode == 401
                ? "Check the \(server.authMode.accountFieldLabel.lowercased()) and secret."
                : ""
            throw JamfError.authenticationFailed("HTTP \(http.statusCode). \(body.prefix(300)) \(hint)")
        }

        switch server.authMode {
        case .apiClient:
            guard let decoded = try? JSONDecoder().decode(OAuthToken.self, from: data) else {
                throw JamfError.authenticationFailed("Unreadable token response.")
            }
            token = decoded.accessToken
            tokenExpiry = Date(timeIntervalSinceNow: decoded.expiresIn)
            return decoded.accessToken
        case .account:
            guard let decoded = try? JSONDecoder().decode(AccountToken.self, from: data) else {
                throw JamfError.authenticationFailed("Unreadable token response.")
            }
            token = decoded.token
            tokenExpiry = Date(timeIntervalSinceNow: 25 * 60)
            return decoded.token
        }
    }

    private func formEncoded(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields
            .map { key, value in
                let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(key)=\(encoded)"
            }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    /// Validates credentials and reports the server version, used by the
    /// connection sheet.
    func verifyCredentials() async throws -> String {
        _ = try await validToken()
        struct Version: Decodable { let version: String }
        let data = try await send(method: "GET", path: "api/v1/jamf-pro-version")
        guard let decoded = try? JSONDecoder().decode(Version.self, from: data) else {
            return "unknown"
        }
        return decoded.version
    }

    // MARK: - Requests

    @discardableResult
    private func send(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = nil,
        retryOnAuthFailure: Bool = true
    ) async throws -> Data {
        let bearer = try await validToken()
        var url = baseURL.appending(path: path)
        if !queryItems.isEmpty { url.append(queryItems: queryItems) }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw JamfError.httpError(statusCode: -1, body: "No HTTP response.")
        }
        if http.statusCode == 401, retryOnAuthFailure {
            token = nil
            return try await send(
                method: method, path: path, queryItems: queryItems,
                body: body, contentType: contentType, retryOnAuthFailure: false
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JamfError.httpError(statusCode: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }

    private struct Page<Element: Decodable>: Decodable {
        let totalCount: Int
        let results: [Element]
    }

    // MARK: - Categories

    func categories() async throws -> [JamfCategory] {
        let data = try await send(
            method: "GET",
            path: "api/v1/categories",
            queryItems: [
                URLQueryItem(name: "page", value: "0"),
                URLQueryItem(name: "page-size", value: "1000"),
                URLQueryItem(name: "sort", value: "name:asc"),
            ]
        )
        do {
            return try JSONDecoder().decode(Page<JamfCategory>.self, from: data).results
        } catch {
            throw JamfError.decodingFailed("categories: \(error.localizedDescription)")
        }
    }

    // MARK: - Packages

    /// Looks for an existing record with the same filename, so a re-upload can
    /// replace it instead of quietly creating a duplicate.
    func existingPackage(fileName: String) async throws -> JamfPackageSummary? {
        let data = try await send(
            method: "GET",
            path: "api/v1/packages",
            queryItems: [
                URLQueryItem(name: "page", value: "0"),
                URLQueryItem(name: "page-size", value: "20"),
                URLQueryItem(name: "filter", value: "fileName==\"\(fileName)\""),
            ]
        )
        guard let page = try? JSONDecoder().decode(Page<JamfPackageSummary>.self, from: data) else {
            return nil
        }
        return page.results.first { $0.fileName == fileName }
    }

    private struct CreatedPackage: Decodable {
        let id: String
    }

    func createPackage(_ metadata: JamfPackageMetadata, sha256: String?) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: metadata.requestBody(sha256: sha256))
        let data = try await send(
            method: "POST",
            path: "api/v1/packages",
            body: body,
            contentType: "application/json"
        )
        guard let created = try? JSONDecoder().decode(CreatedPackage.self, from: data) else {
            throw JamfError.decodingFailed("The server did not return a package id.")
        }
        return created.id
    }

    func updatePackage(id: String, metadata: JamfPackageMetadata, sha256: String?) async throws {
        var object = metadata.requestBody(sha256: sha256)
        // A PUT replaces the whole object, and the Jamf Pro API expects the id
        // to be part of it.
        object["id"] = id
        let body = try JSONSerialization.data(withJSONObject: object)
        try await send(
            method: "PUT",
            path: "api/v1/packages/\(id)",
            body: body,
            contentType: "application/json"
        )
    }

    /// Removes a package record. Used to clean up after an upload that failed
    /// partway — a record with no file behind it is worse than no record.
    func deletePackage(id: String) async throws {
        try await send(method: "DELETE", path: "api/v1/packages/\(id)")
    }

    /// Uploads the file to an existing package record.
    ///
    /// The body is streamed from a staged multipart file — the alternative is
    /// holding the whole package in memory.
    func uploadPackageFile(
        packageID: String,
        multipart: MultipartFileBody.Prepared,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let bearer = try await validToken()
        var request = URLRequest(url: baseURL.appending(path: "api/v1/packages/\(packageID)/upload"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(multipart.boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 6 * 60 * 60

        let delegate = UploadProgressDelegate(onProgress: onProgress)
        let (data, response) = try await session.upload(
            for: request,
            fromFile: multipart.bodyURL,
            delegate: delegate
        )

        guard let http = response as? HTTPURLResponse else {
            throw JamfError.httpError(statusCode: -1, body: "No HTTP response.")
        }
        if http.statusCode == 404 {
            throw JamfError.uploadUnsupported((try? await verifyCredentials()) ?? "unknown version")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JamfError.httpError(statusCode: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
    }

    /// Packages live under Settings → Computer Management in the web UI, not
    /// under the Computers tab.
    nonisolated func packageURL(id: String) -> URL {
        baseURL.appending(path: "view/settings/computer-management/packages/\(id)")
    }
}
