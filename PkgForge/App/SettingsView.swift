import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(SettingsNavigator.self) private var navigator

    var body: some View {
        @Bindable var navigator = navigator

        TabView(selection: $navigator.selection) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) {
                GeneralSettings()
            }
            Tab("Jamf Pro", systemImage: "server.rack", value: SettingsTab.jamfPro) {
                JamfServersSettings()
            }
            Tab("Profiles", systemImage: "doc.text.magnifyingglass", value: SettingsTab.profiles) {
                ProfilesSettings()
            }
        }
        .frame(width: 700, height: 520)
    }
}

// MARK: - Defaults for new apps

struct GeneralSettings: View {
    @Environment(DefaultsStore.self) private var defaults

    var body: some View {
        @Bindable var defaults = defaults

        Form {
            Section {
                LabeledContent("Install Location") {
                    TextField("Install Location", text: $defaults.template.installLocation)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .labelsHidden()
                }

                LabeledContent("Output Folder") {
                    HStack(spacing: 8) {
                        Text(defaults.template.outputDirectory.path(percentEncoded: false))
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose") { chooseOutputDirectory() }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                }

                LabeledContent("Quit Timeout") {
                    HStack(spacing: 8) {
                        TextField("Seconds", value: $defaults.template.quitTimeout, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .frame(width: 70)
                        Stepper("Seconds", value: $defaults.template.quitTimeout, in: 0...600)
                            .labelsHidden()
                        Text("seconds").foregroundStyle(.secondary)
                    }
                }

                Toggle("Always install to the location above", isOn: $defaults.template.preventRelocation)
                Toggle("Abort the install if the app cannot be stopped", isOn: $defaults.template.abortIfRunning)
                Toggle("Remove stray copies found elsewhere on disk", isOn: $defaults.template.removeStrayCopies)
            } header: {
                Text("Defaults for New Apps")
            } footer: {
                Text("Used when an app is dropped that has no saved profile. An app you have built before comes back from its profile instead, and is unaffected by anything here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Default Per-User Cleanup Paths") {
                PathListEditor(
                    title: "Per-user paths",
                    caption: "Relative to each home directory. ${BUNDLE_ID} and ${APP_NAME} are expanded per app.",
                    text: $defaults.template.userStalePaths,
                    placeholder: PackageConfiguration.defaultUserStalePaths
                )
            }

            Section {
                HStack {
                    Button("Reset to Stock Defaults") { defaults.reset() }
                        .disabled(!defaults.isCustomised)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = defaults.template.outputDirectory
        if panel.runModal() == .OK, let url = panel.url {
            defaults.template.outputDirectoryPath = url.path(percentEncoded: false)
        }
    }
}

// MARK: - Jamf Pro logins

struct JamfServersSettings: View {
    @Environment(JamfSession.self) private var jamf

    @State private var selection: UUID?
    @State private var editing: JamfServer?
    @State private var isNew = false

    var body: some View {
        VStack(spacing: 0) {
            if jamf.servers.isEmpty {
                ContentUnavailableView {
                    Label("No Jamf Pro logins", systemImage: "server.rack")
                } description: {
                    Text("Add a login to upload finished packages straight to Jamf Pro.")
                } actions: {
                    Button("Add Login") { addServer() }
                        .buttonStyle(.glassProminent)
                }
                .frame(maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(jamf.servers) { server in
                        HStack(spacing: 12) {
                            Image(systemName: isLive(server) ? "bolt.horizontal.circle.fill" : "server.rack")
                                .foregroundStyle(isLive(server) ? Color.green : .secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.displayName)
                                    .font(.body.weight(.medium))
                                Text("\(server.host) · \(server.authMode.label) · \(server.account)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 8)

                            if !jamf.hasStoredSecret(for: server) {
                                Label("No secret saved", systemImage: "key.slash")
                                    .labelStyle(.iconOnly)
                                    .foregroundStyle(.orange)
                                    .help("No \(server.authMode.secretFieldLabel.lowercased()) in the keychain for this login.")
                            }

                            // Spelled out rather than hidden behind a
                            // right-click: an action nobody can see is an
                            // action nobody uses.
                            HStack(spacing: 6) {
                                Button(isLive(server) ? "Connected" : "Connect") {
                                    Task { await jamf.switchTo(server) }
                                }
                                .disabled(isLive(server) || !jamf.hasStoredSecret(for: server))

                                Button("Edit") { edit(server) }

                                Button("Remove", role: .destructive) {
                                    if selection == server.id { selection = nil }
                                    jamf.remove(server)
                                }
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .fixedSize()
                        }
                        .padding(.vertical, 4)
                        .tag(server.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { edit(server) }
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack(spacing: 10) {
                // Edit and Remove live on the rows themselves, so the only
                // thing left down here is the one action no row can offer.
                Button("Add Login", systemImage: "plus") { addServer() }

                Spacer()

                if case .failed(let message) = jamf.status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
        .sheet(item: $editing) { server in
            JamfServerEditor(draft: server, isNew: isNew)
        }
    }

    private func isLive(_ server: JamfServer) -> Bool {
        jamf.activeServerID == server.id && jamf.status.isConnected
    }

    private func addServer() {
        isNew = true
        editing = JamfServer()
    }

    private func edit(_ server: JamfServer) {
        isNew = false
        editing = server
    }
}

struct JamfServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(JamfSession.self) private var jamf

    @State var draft: JamfServer
    let isNew: Bool

    @State private var secret = ""
    @State private var testResult: TestResult?
    @State private var isTesting = false

    private enum TestResult: Equatable {
        case success(String)
        case failure(String)
    }

    private var hasStoredSecret: Bool {
        !isNew && jamf.hasStoredSecret(for: draft)
    }

    private var canSave: Bool {
        !JamfServer.normalizedURLString(draft.urlString).isEmpty
            && !draft.account.isEmpty
            && (hasStoredSecret || !secret.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("Production"))
                    TextField("Server URL", text: $draft.urlString, prompt: Text("https://yourorg.jamfcloud.com"))
                        .textContentType(.URL)
                    Picker("Authentication", selection: $draft.authMode) {
                        ForEach(JamfAuthMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    TextField(draft.authMode.accountFieldLabel, text: $draft.account)
                    SecureField(
                        draft.authMode.secretFieldLabel,
                        text: $secret,
                        prompt: hasStoredSecret ? Text("Saved in Keychain") : Text(draft.authMode.secretFieldLabel)
                    )
                } footer: {
                    Text(draft.authMode == .apiClient
                         ? "Create an API client under Settings → System → API Roles and Clients. It needs Create, Read and Update on Packages, plus Read on Categories."
                         : "A Jamf Pro user account with package privileges. API clients are preferred — they can be scoped far more tightly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if let testResult {
                    Section {
                        switch testResult {
                        case .success(let version):
                            Label("Connected — Jamf Pro \(version)", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .failure(let message):
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack(spacing: 10) {
                Button("Test Connection") { Task { await test() } }
                    .buttonStyle(.glass)
                    .disabled(!canSave || isTesting)
                if isTesting { ProgressView().controlSize(.small) }

                Spacer()

                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                Button("Save") { save() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(14)
        }
        .frame(width: 520, height: 420)
    }

    private func resolvedSecret() -> String? {
        if !secret.isEmpty { return secret }
        return KeychainStore.secret(for: draft)
    }

    private func test() async {
        isTesting = true
        defer { isTesting = false }

        var probe = draft
        probe.urlString = JamfServer.normalizedURLString(draft.urlString)

        guard let resolved = resolvedSecret(), !resolved.isEmpty else {
            testResult = .failure("Enter the \(draft.authMode.secretFieldLabel.lowercased()) first.")
            return
        }
        do {
            let client = try JamfClient(server: probe, secret: resolved)
            testResult = .success(try await client.verifyCredentials())
        } catch {
            testResult = .failure(error.localizedDescription)
        }
    }

    private func save() {
        jamf.save(draft, secret: secret.isEmpty ? nil : secret)
        dismiss()
    }
}

// MARK: - Saved profiles

struct ProfilesSettings: View {
    @Environment(ProfileStore.self) private var profiles

    @State private var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            if profiles.profiles.isEmpty {
                ContentUnavailableView(
                    "No saved profiles",
                    systemImage: "doc.text",
                    description: Text("After a successful build, PkgForge saves that app's configuration here and prefills it the next time the same bundle identifier is dropped.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(profiles.profiles) { profile in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.appName)
                                    .font(.body.weight(.medium))
                                Text(profile.bundleIdentifier)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(summary(for: profile))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }

                            Spacer(minLength: 8)

                            VStack(alignment: .trailing, spacing: 6) {
                                Text(profile.savedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("Delete", role: .destructive) {
                                    if selection == profile.bundleIdentifier { selection = nil }
                                    profiles.delete(profile)
                                }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                            }
                            .fixedSize()
                        }
                        .padding(.vertical, 4)
                        .tag(profile.bundleIdentifier)
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack(spacing: 10) {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: profiles.directoryPath)
                }

                Spacer()

                Button("Reload") { profiles.reload() }
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
    }

    private func summary(for profile: BuildProfile) -> String {
        let root = profile.configuration.resolvedRootPathCount
        let user = profile.configuration.resolvedUserPathCount
        var parts = ["\(root) root path\(root == 1 ? "" : "s")", "\(user) per-user path\(user == 1 ? "" : "s")"]
        if profile.jamfMetadata != nil { parts.append("Jamf metadata saved") }
        return parts.joined(separator: " · ")
    }
}

extension PackageConfiguration {
    /// Counts without needing a bundle to expand tokens against.
    var resolvedRootPathCount: Int {
        rootStalePaths.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    var resolvedUserPathCount: Int {
        userStalePaths.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }
}
