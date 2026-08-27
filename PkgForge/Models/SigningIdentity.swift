// Copyright 2026 Vantine Imaging LLC
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Security

/// A codesigning identity in the user's keychains.
struct SigningIdentity: Identifiable, Hashable, Sendable {
    var id: String { sha1 }
    let sha1: String
    let name: String
    let expires: Date?

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

    /// Two certificates for the same team have identical common names, so the
    /// expiry is what tells them apart in the picker.
    var menuLabel: String {
        guard let expires else { return shortName }
        return "\(shortName) — expires \(expires.formatted(date: .abbreviated, time: .omitted))"
    }

    var daysUntilExpiry: Int? {
        guard let expires else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: expires).day
    }

    var isExpiringSoon: Bool {
        guard let days = daysUntilExpiry else { return false }
        return days < 90
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

        let expiries = expiryDates()
        let pattern = /^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"(.+)"\s*$/
        var identities: [SigningIdentity] = []

        for line in result.standardOutput.split(separator: "\n") {
            guard let match = line.wholeMatch(of: pattern) else { continue }
            let sha1 = String(match.1).uppercased()
            let identity = SigningIdentity(
                sha1: sha1,
                name: String(match.2),
                expires: expiries[sha1]
            )
            if identity.isInstallerIdentity {
                identities.append(identity)
            }
        }

        // Longest-lived first: when a certificate has been reissued, both are
        // present and the new one is almost always what you want.
        return identities.sorted {
            switch ($0.expires, $1.expires) {
            case let (lhs?, rhs?) where lhs != rhs: lhs > rhs
            default: $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    /// Expiry per certificate, keyed by the SHA-1 fingerprint `security`
    /// reports — read straight from the keychain rather than shelled out to
    /// `openssl`.
    private static func expiryDates() -> [String: Date] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let identities = result as? [SecIdentity]
        else { return [:] }

        var dates: [String: Date] = [:]
        for identity in identities {
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
                  let certificate
            else { continue }

            let der = SecCertificateCopyData(certificate) as Data
            let fingerprint = Insecure.SHA1.hash(data: der)
                .map { String(format: "%02X", $0) }
                .joined()

            guard let values = SecCertificateCopyValues(
                certificate,
                [kSecOIDX509V1ValidityNotAfter] as CFArray,
                nil
            ) as? [String: Any],
                let entry = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
                let seconds = entry[kSecPropertyKeyValue as String] as? Double
            else { continue }

            dates[fingerprint] = Date(timeIntervalSinceReferenceDate: seconds)
        }
        return dates
    }
}
