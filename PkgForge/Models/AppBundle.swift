// Copyright 2026 Vantine Imaging LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The facts read out of a dropped `.app` (M-1, M-2).
struct AppBundle: Sendable, Equatable, Identifiable {
    var id: URL { url }

    let url: URL
    /// Filename minus `.app`. Everything the generated scripts touch on disk
    /// keys off this, never off `CFBundleName` — an app whose display name
    /// differs from its filename must still be found and removed.
    let onDiskName: String
    let bundleIdentifier: String
    /// `CFBundleName`, falling back to the filename when absent (M-3).
    let displayName: String
    let shortVersion: String
    let buildVersion: String
    let executableName: String?
    let minimumSystemVersion: String?

    /// The version the form starts from (C-2), preferring the marketing string.
    var preferredVersion: String {
        shortVersion.isEmpty ? buildVersion : shortVersion
    }
}

enum BundleInspectionError: LocalizedError {
    case notAnApplicationBundle(String)
    case missingInfoPlist
    case unreadableInfoPlist(String)
    case missingBundleIdentifier

    var errorDescription: String? {
        switch self {
        case .notAnApplicationBundle(let name):
            "“\(name)” is not an application bundle. Drop a .app."
        case .missingInfoPlist:
            "That bundle has no Contents/Info.plist."
        case .unreadableInfoPlist(let detail):
            "Contents/Info.plist could not be read: \(detail)"
        case .missingBundleIdentifier:
            """
            That bundle has no CFBundleIdentifier. PkgForge will not invent one \
            — a package with the wrong identifier silently upgrades a different \
            app. Fix the bundle and try again.
            """
        }
    }
}

/// Result of `codesign --display --verbose=2` (M-5). Advisory only: unsigned
/// in-house builds are legitimate.
struct SignatureInfo: Sendable, Equatable {
    var isSigned: Bool
    var authority: String?
    var teamIdentifier: String?
    var detail: String
    /// `com.apple.security.get-task-allow` — the entitlement that lets a
    /// debugger attach. Xcode injects it into any build with base entitlements
    /// injected, Release included, and Apple's notary service rejects every
    /// executable carrying it.
    var hasDebugEntitlement: Bool = false
    /// Hardened Runtime, which notarization also requires.
    var hasHardenedRuntime: Bool = false
}

/// Payload size and file count (M-6), so a 4 GB app is obvious before the build.
struct BundleStats: Sendable, Equatable {
    var byteCount: Int64
    var fileCount: Int

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

enum BundleInspector {

    /// Parses a bundle's `Info.plist`. `PropertyListSerialization` handles
    /// binary and XML plists alike — a text parser would fail on roughly half
    /// the apps in `/Applications` (M-1).
    static func inspect(url: URL) throws -> AppBundle {
        let name = url.lastPathComponent

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue, url.pathExtension.lowercased() == "app" else {
            throw BundleInspectionError.notAnApplicationBundle(name)
        }

        let plistURL = url.appending(path: "Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: plistURL.path(percentEncoded: false)) else {
            throw BundleInspectionError.missingInfoPlist
        }

        let data: Data
        do {
            data = try Data(contentsOf: plistURL)
        } catch {
            throw BundleInspectionError.unreadableInfoPlist(error.localizedDescription)
        }

        let plist: [String: Any]
        do {
            let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
            guard let dictionary = parsed as? [String: Any] else {
                throw BundleInspectionError.unreadableInfoPlist("The plist root is not a dictionary.")
            }
            plist = dictionary
        } catch let error as BundleInspectionError {
            throw error
        } catch {
            throw BundleInspectionError.unreadableInfoPlist(error.localizedDescription)
        }

        let onDiskName = url.deletingPathExtension().lastPathComponent

        let identifier = string(plist["CFBundleIdentifier"])
        guard !identifier.isEmpty else {
            throw BundleInspectionError.missingBundleIdentifier
        }

        let bundleName = string(plist["CFBundleName"])

        return AppBundle(
            url: url,
            onDiskName: onDiskName,
            bundleIdentifier: identifier,
            displayName: bundleName.isEmpty ? onDiskName : bundleName,
            shortVersion: string(plist["CFBundleShortVersionString"]),
            buildVersion: string(plist["CFBundleVersion"]),
            executableName: optionalString(plist["CFBundleExecutable"]),
            minimumSystemVersion: optionalString(plist["LSMinimumSystemVersion"])
        )
    }

    /// Reads the entitlements `codesign` embedded in the bundle.
    private static func entitlements(of url: URL) async -> [String: Any] {
        guard let result = try? await ProcessRunner.run(
            "/usr/bin/codesign",
            ["-d", "--entitlements", "-", "--xml", url.path(percentEncoded: false)]
        ), result.succeeded else { return [:] }

        // codesign puts the plist on stdout and its chatter on stderr.
        guard let data = result.standardOutput.data(using: .utf8),
              let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = parsed as? [String: Any]
        else { return [:] }
        return dictionary
    }

    /// `codesign` writes its report to stderr, which is why both pipes matter.
    static func signature(of url: URL) async -> SignatureInfo {
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                "/usr/bin/codesign",
                ["--display", "--verbose=2", url.path(percentEncoded: false)]
            )
        } catch {
            return SignatureInfo(isSigned: false, authority: nil, teamIdentifier: nil, detail: error.localizedDescription)
        }

        let report = result.standardError.isEmpty ? result.standardOutput : result.standardError
        guard result.succeeded else {
            return SignatureInfo(
                isSigned: false,
                authority: nil,
                teamIdentifier: nil,
                detail: report.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let lines = report.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let authority = lines
            .first { $0.hasPrefix("Authority=") }
            .map { String($0.dropFirst("Authority=".count)) }
        let team = lines
            .first { $0.hasPrefix("TeamIdentifier=") }
            .map { String($0.dropFirst("TeamIdentifier=".count)) }
            .flatMap { $0 == "not set" ? nil : $0 }

        // An ad-hoc signature reports no Authority line at all.
        let adHoc = lines.contains { $0.contains("Signature=adhoc") }

        // `flags=0x10000(runtime)` is Hardened Runtime.
        let hardened = lines.contains { $0.contains("flags=") && $0.contains("runtime") }

        let claims = await entitlements(of: url)
        let debuggable = (claims["com.apple.security.get-task-allow"] as? Bool) == true

        return SignatureInfo(
            isSigned: !adHoc && authority != nil,
            authority: adHoc ? "Ad-hoc signature" : authority,
            teamIdentifier: team,
            detail: report.trimmingCharacters(in: .whitespacesAndNewlines),
            hasDebugEntitlement: debuggable,
            hasHardenedRuntime: hardened
        )
    }

    /// Walks the bundle for size and file count. Runs off the main actor —
    /// a large bundle can hold six figures of files.
    static func stats(of url: URL) -> BundleStats {
        var bytes: Int64 = 0
        var files = 0

        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            return BundleStats(byteCount: 0, fileCount: 0)
        }

        for case let element as URL in enumerator {
            guard let values = try? element.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            files += 1
            bytes += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }

        return BundleStats(byteCount: bytes, fileCount: files)
    }

    private static func string(_ value: Any?) -> String {
        optionalString(value) ?? ""
    }

    private static func optionalString(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
