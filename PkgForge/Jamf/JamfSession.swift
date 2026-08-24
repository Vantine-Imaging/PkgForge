import Foundation
import Observation

/// Saved Jamf Pro logins plus the connection state of the active one.
@MainActor
@Observable
final class JamfSession {

    enum Status: Equatable {
        case idle
        case connecting
        case connected(version: String)
        case failed(String)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    private(set) var status: Status = .idle
    private(set) var client: JamfClient?
    private(set) var activeServerID: UUID?
    private(set) var categories: [JamfCategory] = []

    private(set) var servers: [JamfServer] = [] {
        didSet { persist() }
    }

    private static let serversKey = "jamf.servers"
    private static let lastServerKey = "jamf.lastServerID"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.serversKey),
           let saved = try? JSONDecoder().decode([JamfServer].self, from: data) {
            servers = saved
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: Self.serversKey)
        }
    }

    var activeServer: JamfServer? {
        servers.first { $0.id == activeServerID }
    }

    /// The server to offer first: the last one connected to, else the first saved.
    var preferredServer: JamfServer? {
        if let active = activeServer { return active }
        if let raw = UserDefaults.standard.string(forKey: Self.lastServerKey),
           let id = UUID(uuidString: raw),
           let match = servers.first(where: { $0.id == id }) {
            return match
        }
        return servers.first
    }

    func hasStoredSecret(for server: JamfServer) -> Bool {
        KeychainStore.secret(for: server) != nil
    }

    // MARK: - Managing saved logins

    /// Adds or updates a login. Matching is on URL + auth mode + account, so
    /// renaming an existing entry does not create a second one.
    @discardableResult
    func save(_ server: JamfServer, secret: String?) -> JamfServer {
        var record = server
        record.urlString = JamfServer.normalizedURLString(server.urlString)

        if let index = servers.firstIndex(where: { $0.id == record.id }) {
            let previous = servers[index]
            // The keychain item is keyed by the connection details; if they
            // changed, the old secret is now unreachable and should go.
            if previous.urlString != record.urlString
                || previous.account != record.account
                || previous.authMode != record.authMode {
                KeychainStore.delete(for: previous)
            }
            servers[index] = record
        } else if let index = servers.firstIndex(where: {
            $0.urlString == record.urlString && $0.account == record.account && $0.authMode == record.authMode
        }) {
            record.id = servers[index].id
            servers[index] = record
        } else {
            servers.append(record)
        }

        if let secret, !secret.isEmpty {
            try? KeychainStore.save(secret, for: record)
        }
        return record
    }

    func remove(_ server: JamfServer) {
        KeychainStore.delete(for: server)
        servers.removeAll { $0.id == server.id }
        if activeServerID == server.id { disconnect() }
    }

    // MARK: - Connecting

    func connect(to server: JamfServer, secret: String? = nil) async {
        guard server.url != nil else {
            status = .failed("Enter the full server URL, e.g. https://yourorg.jamfcloud.com")
            return
        }
        guard !server.account.isEmpty else {
            status = .failed("Enter the \(server.authMode.accountFieldLabel.lowercased()).")
            return
        }
        guard let resolved = secret ?? KeychainStore.secret(for: server), !resolved.isEmpty else {
            status = .failed("No saved \(server.authMode.secretFieldLabel.lowercased()) for \(server.displayName).")
            return
        }

        status = .connecting
        do {
            let candidate = try JamfClient(server: server, secret: resolved)
            let version = try await candidate.verifyCredentials()
            if secret != nil {
                try? KeychainStore.save(resolved, for: server)
            }
            client = candidate
            activeServerID = server.id
            UserDefaults.standard.set(server.id.uuidString, forKey: Self.lastServerKey)
            status = .connected(version: version)
            await loadCategories()
        } catch {
            client = nil
            activeServerID = nil
            categories = []
            status = .failed(error.localizedDescription)
        }
    }

    func switchTo(_ server: JamfServer) async {
        client = nil
        categories = []
        await connect(to: server)
    }

    func disconnect() {
        client = nil
        activeServerID = nil
        categories = []
        status = .idle
    }

    private func loadCategories() async {
        guard let client else { return }
        categories = (try? await client.categories()) ?? []
    }
}
