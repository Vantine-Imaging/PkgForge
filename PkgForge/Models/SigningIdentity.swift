import Foundation

/// A codesigning identity in the user's keychains.
struct SigningIdentity: Identifiable, Hashable, Sendable {
    var id: String { sha1 }
    let sha1: String
    let name: String

    /// Only `Developer ID Installer` identities can sign a `.pkg`. A package
    /// signed with a `Developer ID Application` identity is rejected at
    /// install time, so those must never reach the picker (C-10).
    var isInstallerIdentity: Bool {
        name.hasPrefix("Developer ID Installer:")
    }

    /// The organisation portion, for a tidier menu label.
    var shortName: String {
        guard let range = name.range(of: "Developer ID Installer: ") else { return name }
        return String(name[range.upperBound...])
    }
}

enum SigningIdentityLoader {

    /// Parses `security find-identity -v -p basic`, whose lines look like:
    /// `  1) A1B2C3… "Developer ID Installer: Example Corp (AB12CD34EF)"`
    static func load() async -> [SigningIdentity] {
        guard let result = try? await ProcessRunner.run(
            "/usr/bin/security",
            ["find-identity", "-v", "-p", "basic"]
        ) else { return [] }

        let pattern = /^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"(.+)"\s*$/
        var identities: [SigningIdentity] = []

        for line in result.standardOutput.split(separator: "\n") {
            guard let match = line.wholeMatch(of: pattern) else { continue }
            let identity = SigningIdentity(sha1: String(match.1), name: String(match.2))
            if identity.isInstallerIdentity {
                identities.append(identity)
            }
        }

        return identities.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
