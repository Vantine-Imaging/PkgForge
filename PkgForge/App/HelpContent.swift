// Copyright 2026 Vantine Imaging LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One block of help prose. Kept as data rather than a web view so the text is
/// selectable, searchable and themed like the rest of the app.
enum HelpBlock: Hashable {
    case heading(String)
    case paragraph(String)
    case bullets([String])
    case code(String)
    case note(String)
    case warning(String)
}

struct HelpTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let summary: String
    let blocks: [HelpBlock]
}

enum HelpBook {
    static let topics: [HelpTopic] = [
        gettingStarted, reading, scripts, cleanup, additionalScripts, signing, jamf, profiles,
        troubleshooting, license,
    ]

    static func topic(id: String) -> HelpTopic {
        topics.first { $0.id == id } ?? gettingStarted
    }

    // MARK: -

    static let gettingStarted = HelpTopic(
        id: "getting-started",
        title: "Getting Started",
        symbol: "sparkles",
        summary: "From a dropped app to a deployable package.",
        blocks: [
            .paragraph("PkgForge turns an application bundle into an installer package that replaces the app cleanly on a Mac someone is actively using — stopping the running copy first, clearing out the leftovers, and handing the installer a payload with the right ownership."),
            .heading("The short version"),
            .bullets([
                "Drop a .app anywhere on the window, or press ⌘O.",
                "Check the form. Everything is prefilled from the bundle and everything is editable.",
                "List the paths that should be cleaned up before the new version lands.",
                "Pick a Developer ID Installer identity, or build unsigned.",
                "Press Build Package (⌘B). Watch the log in the inspector on the right.",
                "Upload it to Jamf Pro, or reveal it in Finder and take it from there.",
            ]),
            .heading("Before you deploy it widely"),
            .paragraph("Read the scripts. Preview Scripts in the toolbar shows exactly what will run as root on every Mac in scope, with your settings already applied. Then install the package on one test Mac with the app open and an unsaved document, and check /var/log/install.log."),
            .note("PkgForge never asks for an administrator password and never installs a helper. It runs entirely as you, and the package it produces is what does the privileged work at install time."),
        ]
    )

    static let reading = HelpTopic(
        id: "reading",
        title: "What PkgForge Reads",
        symbol: "doc.text.magnifyingglass",
        summary: "Where the prefilled values come from.",
        blocks: [
            .paragraph("Everything in the form starts from Contents/Info.plist, parsed as a property list — so binary plists, which are most of them, work exactly like XML ones."),
            .bullets([
                "CFBundleIdentifier becomes the package identifier.",
                "CFBundleShortVersionString becomes the version, falling back to CFBundleVersion.",
                "CFBundleName becomes the display name, falling back to the filename.",
                "LSMinimumSystemVersion is shown for information.",
            ]),
            .heading("Display name versus filename"),
            .paragraph("These are often different — an app called “Bobby (Beta)” can sit on disk as BobsTestApp.app. Every path in the generated scripts uses the filename, because that is what exists on the target Mac. When the two differ, PkgForge shows both."),
            .heading("A missing identifier is fatal"),
            .warning("A bundle with no CFBundleIdentifier is rejected outright. PkgForge will not invent one: an identifier that collides with another package makes this a silent upgrade of something else, and the mistake only surfaces once it has been deployed."),
            .heading("Signature and size"),
            .paragraph("The signing status comes from codesign --display and is advisory only — an unsigned in-house build is a perfectly legitimate payload. The size and file count are there so a four-gigabyte app is obvious before you start the build rather than after."),
        ]
    )

    static let scripts = HelpTopic(
        id: "scripts",
        title: "The Generated Scripts",
        symbol: "terminal",
        summary: "What actually runs, as root, on the target Mac.",
        blocks: [
            .paragraph("Two scripts ship inside every package. Both run as root, and everything they log is timestamped into /var/log/install.log on the target Mac."),
            .heading("preinstall — before the payload is written"),
            .bullets([
                "Resolves the console user. If nobody is logged in, or the session belongs to root, the graceful-quit step is skipped — there is no session to send an Apple event from.",
                "Finds the running app by the executable path it was launched from, not by process name. Process names truncate at fifteen characters and collide between apps.",
                "Asks the app to quit as the logged-in user, so an unsaved-document prompt appears in front of the person actually sitting there.",
                "Polls once a second up to the quit timeout, then escalates: SIGTERM, five seconds, SIGKILL, two seconds.",
                "Unloads any LaunchDaemon or LaunchAgent named in your cleanup lists — reading the real Label out of the plist — before that plist is deleted underneath launchd. Agents are unloaded from every account's session, not just the console user's, so fast user switching does not leave one running.",
                "Removes the existing bundle, then each stale path, each existence-checked and logged individually.",
            ]),
            .heading("If the app will not stop"),
            .paragraph("With “Abort the install if the app cannot be stopped” on — the default — the script exits non-zero and the installation fails. Jamf reports a failed policy, which is the outcome you want: replacing a bundle that is still mapped into a running process leaves the user with an application that is half one version and half another."),
            .heading("postinstall — after the payload lands"),
            .bullets([
                "chown -R root:wheel. A bundle in /Applications owned by a user is a privilege-escalation path — any local account could swap the binary.",
                "chmod -R go-w.",
                "Clears com.apple.quarantine. Installer payloads are not quarantined, but the attribute rides along from the machine the package was built on more often than you would think.",
                "Verifies the code signature, logging a warning if it fails rather than failing the install.",
            ]),
            .note("Every value PkgForge interpolates into these scripts is escaped for the context it lands in — shell-quoted, regex-escaped for pgrep, glob-escaped for find. An app named “Bob's App.app” produces valid, non-injectable bash."),
        ]
    )

    static let cleanup = HelpTopic(
        id: "cleanup",
        title: "Stale Path Cleanup",
        symbol: "trash",
        summary: "The part that takes real thought.",
        blocks: [
            .paragraph("This is the only part of a package that needs judgement, and it does not change between versions of an app. Get it right once and the profile remembers it."),
            .heading("Two lists"),
            .bullets([
                "Root-level paths are absolute and deleted once: /Library/Application Support/…, /Library/LaunchDaemons/…, a stale helper in /usr/local.",
                "Per-user paths are relative to a home directory and applied across every account under /Users. Shared, Guest and dot-directories are skipped.",
            ]),
            .heading("Tokens"),
            .paragraph("Both lists accept two substitutions, expanded when the scripts are generated:"),
            .code("""
            ${BUNDLE_ID}   →  com.example.app
            ${APP_NAME}    →  the on-disk filename, without .app
            """),
            .heading("Paths are literal"),
            .warning("Wildcards are not expanded. A line containing * or ? is deleted as a literal path — which will simply not match anything. PkgForge warns when it sees one."),
            .heading("Preferences"),
            .paragraph("PkgForge warns if a per-user path points at Library/Preferences. Wiping preferences on every upgrade is occasionally what someone means and usually is not — it resets every user's settings each time you ship a new version."),
            .heading("Stray copies"),
            .paragraph("Off by default, and the only option that deletes anything outside the install location. It searches /Applications and every user's ~/Applications two levels deep for a bundle with a matching filename — useful when someone has drag-installed a second, unmanaged copy."),
            .note("Because a filename match is not evidence of identity — more than one vendor ships a “Console.app” — each candidate's CFBundleIdentifier is checked against the package's before it is removed. Anything that does not match is skipped and logged."),
        ]
    )

    static let additionalScripts = HelpTopic(
        id: "additional-scripts",
        title: "Additional Scripts",
        symbol: "chevron.left.forwardslash.chevron.right",
        summary: "Adding your own steps, and why there are only two phases.",
        blocks: [
            .paragraph("A flat package declares its script phases in its PackageInfo, and there are exactly two:"),
            .code("""
            <scripts>
                <preinstall file="./preinstall" timeout="600"/>
                <postinstall file="./postinstall" timeout="600"/>
            </scripts>
            """),
            .paragraph("preflight, postflight, preupgrade and postupgrade belong to pre-10.5 bundle packages. Nothing in a modern package declares them and the installer never runs them, so PkgForge does not offer them as options — they would be files that look like they work and quietly do not."),
            .heading("Your own steps"),
            .bullets([
                "Preinstall additions run either before the app is stopped, or after all cleanup just before the script exits. Pick with the menu above the field.",
                "Postinstall additions run after ownership, permissions and quarantine are corrected, before the signature check.",
            ]),
            .paragraph("These variables are in scope, along with the log() function that timestamps into the installer log:"),
            .code("""
            $APP_NAME          Bobs Test App
            $BUNDLE_ID         com.example.app
            $APP_PATH          /Applications/Bobs Test App.app
            $INSTALL_LOCATION  /Applications
            $CONSOLE_USER      the logged-in user, empty at the login window
            $CONSOLE_UID       their uid
            """),
            .heading("Bundled files"),
            .paragraph("Extra files are copied into the package's Scripts directory. macOS never runs them on its own — your additions have to call them:"),
            .code("""
            "$(/usr/bin/dirname "$0")/vendor-cleanup.sh"
            """),
            .paragraph("Anything starting with #! is made executable; everything else is left non-executable. A file named preinstall or postinstall is refused rather than allowed to replace the generated script."),
            .heading("Syntax is checked before the build"),
            .note("Your snippets are code, so they are spliced in verbatim rather than escaped. PkgForge runs bash -n over both finished scripts and fails the build if either is invalid — an unbalanced quote stops you here instead of producing a package that installs cleanly everywhere and does nothing."),
        ]
    )

    static let signing = HelpTopic(
        id: "signing",
        title: "Signing",
        symbol: "signature",
        summary: "Which identity, and when you need one.",
        blocks: [
            .heading("Installer, not Application"),
            .warning("Only a Developer ID Installer identity can sign a package. A package signed with a Developer ID Application identity is rejected at install time, so PkgForge filters those out of the picker entirely rather than letting you pick one and find out later."),
            .heading("Do you need to sign at all?"),
            .paragraph("For a package Jamf installs as root, no. Gatekeeper is not consulted for an MDM-driven install, and an unsigned package deploys fine. Signing matters when somebody might double-click the package by hand — during testing, or when handing it to another admin."),
            .heading("Checking the result"),
            .paragraph("Every build runs pkgutil --check-signature and puts the result in the log. On an unsigned package it reads “Status: no signature”, which is expected rather than a failure."),
            .heading("Notarization"),
            .paragraph("Optional, and off by default. A package an MDM installs as root bypasses Gatekeeper entirely, so notarization buys nothing there. It matters for the package you double-click on a test Mac, which otherwise needs right-click-Open every time."),
            .paragraph("It needs a notarytool keychain profile, created once per Mac. PkgForge cannot make this for you — it takes your Apple ID and an app-specific password:"),
            .code("""
            xcrun notarytool store-credentials pkgforge-notary \\
              --apple-id you@example.com \\
              --team-id ABCDE12345
            """),
            .paragraph("Then tick “Notarize with Apple after building”, name that profile, and press Verify — which checks the profile resolves before you spend five minutes discovering a typo. Notarization requires a signed package, so the toggle is unavailable until an installer identity is selected."),
            .bullets([
                "The package is submitted and PkgForge waits for a verdict, usually a few minutes.",
                "On acceptance the ticket is stapled, then validated, and the result is logged.",
                "On rejection the notary log is fetched and shown — the verdict alone never says what was wrong.",
            ]),
            .note("A notary rejection fails the build but never deletes the package. It is still built and still signed; it just is not notarized, and you can deploy it via Jamf regardless."),
        ]
    )

    static let jamf = HelpTopic(
        id: "jamf",
        title: "Jamf Pro",
        symbol: "server.rack",
        summary: "Saved logins and uploading a finished package.",
        blocks: [
            .heading("Saving a login"),
            .paragraph("Settings → Jamf Pro holds as many instances as you need and switches between them. Only the URL, auth mode and account are stored in preferences; the secret goes into your login Keychain, keyed so several accounts on one server can coexist. Test Connection validates before you save."),
            .heading("API client privileges"),
            .paragraph("An API client from Settings → System → API Roles and Clients is the better choice — it can be scoped far more tightly than a user account. The role needs:"),
            .bullets([
                "Packages — Create, Read and Update",
                "Categories — Read",
            ]),
            .heading("What the upload does"),
            .bullets([
                "Looks for an existing package with the same filename, and offers to update that record rather than quietly creating a duplicate.",
                "Creates or updates the package record with the metadata from the sheet.",
                "Uploads the file, streamed from disk so a multi-gigabyte package is not held in memory, with a SHA-256 computed on the way past.",
            ]),
            .warning("Uploading through the API needs Jamf Pro 11.5 or later with a cloud distribution point. On an older instance the upload endpoint does not exist and you will get a clear error rather than a hang."),
            .note("If Jamf rejects the package record, the server's own response body is shown verbatim. That message is the only thing worth reading when a record is refused — PkgForge does not replace it with something friendlier and less useful."),
        ]
    )

    static let profiles = HelpTopic(
        id: "profiles",
        title: "Profiles",
        symbol: "clock.arrow.circlepath",
        summary: "Why the second build is a two-click job.",
        blocks: [
            .paragraph("After every successful build, the configuration is saved against the bundle identifier:"),
            .code("~/Library/Application Support/PkgForge/Profiles/<bundleID>.json"),
            .paragraph("Drop the same app again — a new version, months later — and everything comes back from that profile. Only the version is taken from the new bundle, because that is the one thing that genuinely changed."),
            .paragraph("Cleanup lists, install location, quit timeout, signing identity, output folder, your script additions and the Jamf metadata from the last upload all persist. Settings → Profiles lists them and deletes the ones you no longer want."),
            .note("A profile that names a signing identity no longer in your keychain quietly falls back to unsigned rather than failing the build."),
        ]
    )

    static let license = HelpTopic(
        id: "license",
        title: "License",
        symbol: "scroll",
        summary: "Apache-2.0, copyright Vantine Imaging LLC.",
        blocks: [
            .paragraph("PkgForge is copyright 2026 Vantine Imaging LLC and licensed under the Apache License, Version 2.0."),
            .paragraph("You may use, modify and redistribute it, including commercially, provided you keep the copyright and licence notices and state any changes you make. It comes with no warranty of any kind."),
            .code("https://github.com/Vantine-Imaging/PkgForge"),
            .paragraph("The full licence text and the attribution notice are in the LICENSE and NOTICE files in that repository."),
            .note("It was written at Vantine Imaging LLC and is owned by it. It is public because the problem it solves is one every Mac admin has."),
        ]
    )

    static let troubleshooting = HelpTopic(
        id: "troubleshooting",
        title: "Troubleshooting",
        symbol: "stethoscope",
        summary: "When something goes wrong, here and on the target Mac.",
        blocks: [
            .heading("The build failed"),
            .paragraph("pkgbuild's own stderr is in the log, unedited. It is usually specific and usually right. Copy Log puts the whole thing on the clipboard."),
            .heading("The picker has no identities"),
            .paragraph("PkgForge lists only Developer ID Installer identities. Check what you have:"),
            .code("security find-identity -v -p basic"),
            .heading("The package installed but the policy failed"),
            .paragraph("Look at /var/log/install.log on the target Mac — Help → Show the Installer Log opens this Mac's copy. Every line PkgForge's scripts write is prefixed “PkgForge:”."),
            .paragraph("A preinstall that exits 1 means the app could not be stopped. That is deliberate. A postinstall that exits 1 means the bundle was not where it was expected, which usually means the install location and the payload disagree."),
            .heading("The app installed to the wrong place"),
            .paragraph("Leave “Always install to the location above” on. With it off, macOS is allowed to redirect the payload to wherever it finds an existing copy of that bundle identifier — a user's ~/Applications, an old copy on another volume — while the scripts still work against the location you chose."),
            .heading("Verifying on a test Mac"),
            .paragraph("After a build, More → Copy Install Command gives you:"),
            .code("sudo installer -pkg <path> -target / -verbose"),
        ]
    )
}
