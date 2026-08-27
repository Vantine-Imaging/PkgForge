// Copyright 2026 Vantine Imaging LLC
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// The Help menu. Split out so it can pull `openWindow` out of the
/// environment, which command builders in the `App` body cannot.
struct HelpMenuItems: View {
    @Environment(HelpNavigator.self) private var navigator
    @Environment(\.openWindow) private var openWindow

    private static let installerLog = "/var/log/install.log"

    var body: some View {
        Button("PkgForge Help") { open(HelpBook.gettingStarted.id) }
            .keyboardShortcut("?", modifiers: .command)

        Divider()

        Button("The Generated Scripts") { open(HelpBook.scripts.id) }
        Button("Stale Path Cleanup") { open(HelpBook.cleanup.id) }
        Button("Additional Scripts") { open(HelpBook.additionalScripts.id) }
        Button("Signing") { open(HelpBook.signing.id) }
        Button("Connecting to Jamf Pro") { open(HelpBook.jamf.id) }
        Button("Troubleshooting") { open(HelpBook.troubleshooting.id) }
        Button("License") { open(HelpBook.license.id) }

        Divider()

        Button("Show the Installer Log") { showInstallerLog() }
        Button("Show the Profiles Folder") { showProfilesFolder() }
    }

    private func open(_ topic: String) {
        navigator.selection = topic
        openWindow(id: "help")
    }

    /// Opens this Mac's own installer log — the same file the generated
    /// scripts write into on a target Mac.
    private func showInstallerLog() {
        let url = URL(fileURLWithPath: Self.installerLog)
        guard FileManager.default.fileExists(atPath: Self.installerLog) else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: "/var/log")
            return
        }
        if let console = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") {
            NSWorkspace.shared.open([url], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.selectFile(Self.installerLog, inFileViewerRootedAtPath: "/var/log")
        }
    }

    private func showProfilesFolder() {
        let path = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "PkgForge/Profiles")
            .path(percentEncoded: false)
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }
}
