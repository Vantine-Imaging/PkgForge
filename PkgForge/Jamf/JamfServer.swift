import Foundation

/// How PkgForge authenticates to a Jamf Pro instance.
enum JamfAuthMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Settings → System → API Roles and Clients. The recommended path.
    case apiClient
    /// A Jamf Pro user account, exchanged for a bearer token.
    case account

    var id: String { rawValue }

    var label: String {
        switch self {
        case .apiClient: "API Client"
        case .account: "Jamf Pro Account"
        }
    }

    var accountFieldLabel: String {
        switch self {
        case .apiClient: "Client ID"
        case .account: "Username"
        }
    }

    var secretFieldLabel: String {
        switch self {
        case .apiClient: "Client Secret"
        case .account: "Password"
        }
    }
}

/// A saved Jamf Pro login. The secret never lives here — it is in the login
/// Keychain, keyed by URL + auth mode + account.
struct JamfServer: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String = ""
    var urlString: String = ""
    var authMode: JamfAuthMode = .apiClient
    var account: String = ""

    var host: String {
        URL(string: urlString)?.host() ?? urlString
    }

    var displayName: String {
        name.trimmingCharacters(in: .whitespaces).isEmpty ? host : name
    }

    var url: URL? {
        guard let url = URL(string: urlString), url.scheme == "https", url.host() != nil else { return nil }
        return url
    }

    static func normalizedURLString(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if !trimmed.isEmpty, !trimmed.lowercased().hasPrefix("http") {
            trimmed = "https://" + trimmed
        }
        return trimmed
    }
}
