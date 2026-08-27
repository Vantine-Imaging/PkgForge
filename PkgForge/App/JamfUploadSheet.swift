// Copyright 2026 Vantine Imaging LLC
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// Uploads the finished package to a saved Jamf Pro instance.
struct JamfUploadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @Environment(BuildController.self) private var controller
    @Environment(JamfSession.self) private var jamf
    @Environment(SettingsNavigator.self) private var settingsNavigator

    @State private var model = JamfUploadModel()
    @State private var selectedServerID: UUID?
    @State private var secret = ""

    private var selectedServer: JamfServer? {
        jamf.servers.first { $0.id == selectedServerID }
    }

    private var isConnectedToSelection: Bool {
        jamf.status.isConnected && jamf.activeServerID == selectedServerID
    }

    private var needsSecret: Bool {
        guard let selectedServer else { return false }
        return !jamf.hasStoredSecret(for: selectedServer)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Form {
                serverSection

                if isConnectedToSelection {
                    metadataSection
                    optionsSection
                }
            }
            .formStyle(.grouped)
            .disabled(model.isBusy)

            Divider()
            footer
        }
        .frame(width: 620, height: 640)
        .task {
            guard let packageURL = controller.finishedPackageURL else { return }
            model.prepare(
                for: packageURL,
                bundle: controller.bundle,
                configuration: controller.configuration,
                remembered: controller.savedJamfMetadata,
                previousVersion: controller.savedJamfMetadataVersion
            )
            selectedServerID = jamf.preferredServer?.id
            if let server = selectedServer, jamf.hasStoredSecret(for: server), !jamf.status.isConnected {
                await jamf.connect(to: server)
                await refreshDuplicate()
            } else if isConnectedToSelection {
                await refreshDuplicate()
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.finishedPackageURL?.lastPathComponent ?? "No package")
                    .font(.headline)
                if case .finished(let outcome) = controller.phase {
                    Text(ByteCountFormatter.string(fromByteCount: outcome.byteCount, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(18)
    }

    @ViewBuilder
    private var serverSection: some View {
        Section("Jamf Pro") {
            if jamf.servers.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No saved logins yet.")
                        .foregroundStyle(.secondary)
                    Button("Add a Jamf Pro Login") { showJamfSettings() }
                        .buttonStyle(.glass)
                }
                .padding(.vertical, 4)
            } else {
                Picker("Server", selection: $selectedServerID) {
                    ForEach(jamf.servers) { server in
                        Text(server.displayName).tag(Optional(server.id))
                    }
                }
                .onChange(of: selectedServerID) {
                    secret = ""
                    Task { await connectIfPossible() }
                }

                if let server = selectedServer {
                    LabeledContent("URL") {
                        Text(server.urlString)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    LabeledContent(server.authMode.accountFieldLabel) {
                        Text(server.account)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if !isConnectedToSelection {
                    if needsSecret, let server = selectedServer {
                        SecureField(server.authMode.secretFieldLabel, text: $secret)
                    }
                    HStack(spacing: 10) {
                        Button("Connect") {
                            Task { await connect() }
                        }
                        .buttonStyle(.glass)
                        .disabled(selectedServer == nil || jamf.status == .connecting || (needsSecret && secret.isEmpty))

                        if jamf.status == .connecting {
                            ProgressView().controlSize(.small)
                        }
                    }
                }

                statusLine
            }

            Button("Manage Logins") { showJamfSettings() }
                .buttonStyle(.link)
                .font(.callout)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch jamf.status {
        case .connected(let version) where jamf.activeServerID == selectedServerID:
            Label("Connected — Jamf Pro \(version)", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var metadataSection: some View {
        Section("Package Record") {
            LabeledContent("Display Name") {
                TextField("Display Name", text: $model.metadata.displayName)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    // Editing the name changes what it might collide with.
                    .onSubmit { Task { await refreshDuplicate() } }
            }
            LabeledContent("Filename") {
                Text(model.metadata.fileName)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
            Picker("Category", selection: $model.metadata.categoryID) {
                Text("None").tag("-1")
                ForEach(jamf.categories) { category in
                    Text(category.name).tag(category.id)
                }
            }
            LabeledContent("Priority") {
                HStack(spacing: 8) {
                    TextField("Priority", value: $model.metadata.priority, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 60)
                    Stepper("Priority", value: $model.metadata.priority, in: 1...20)
                        .labelsHidden()
                }
            }
            LabeledContent("Info") {
                TextField("Info", text: $model.metadata.info, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .lineLimit(1...3)
            }
            LabeledContent("Notes") {
                TextField("Notes", text: $model.metadata.notes, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .lineLimit(1...3)
            }
        }
    }

    @ViewBuilder
    private var optionsSection: some View {
        Section("Options") {
            Toggle("Reboot required", isOn: $model.metadata.rebootRequired)
            Toggle("Fill user template", isOn: $model.metadata.fillUserTemplate)
            Toggle("Suppress from Dock", isOn: $model.metadata.suppressFromDock)
            Toggle("Suppress updates", isOn: $model.metadata.suppressUpdates)

            if let duplicate = model.duplicate {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text(model.duplicatePointsElsewhere
                             ? "A package record named “\(duplicate.packageName)” (id \(duplicate.id)) already exists, pointing at \(duplicate.fileName). Replacing it repoints it at this package."
                             : "\(duplicate.fileName) already exists on this server as “\(duplicate.packageName)” (id \(duplicate.id)).")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.callout)
                    .foregroundStyle(.orange)

                    Picker("", selection: $model.replaceExisting) {
                        Text("Replace the existing record").tag(true)
                        Text("Create a second record").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()

                    if model.duplicatesDisplayName && !model.replaceExisting {
                        Label(
                            "Jamf Pro requires package display names to be unique, so a second record needs a different display name.",
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.red)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 12) {
            switch model.phase {
            case .preparing:
                ProgressView().controlSize(.small)
                Text("Staging the upload…").foregroundStyle(.secondary)
            case .checkingForDuplicate:
                ProgressView().controlSize(.small)
                Text("Checking for an existing package…").foregroundStyle(.secondary)
            case .uploading:
                ProgressView(value: model.progressFraction ?? 0)
                    .progressViewStyle(.linear)
                    .frame(width: 180)
                if let description = model.progressDescription {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            case .finished(let packageID):
                VStack(alignment: .leading, spacing: 3) {
                    Label("Uploaded as package \(packageID)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if let warning = model.warning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                }
            case .failed(let message):
                // Scrolls rather than clips: Jamf's 400 body is where the
                // offending field is named, and it is several lines long.
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    ScrollView {
                        Text(message)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 96)
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message, forType: .string)
                    }
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .help("Copy the full error")
                }
            case .editing:
                EmptyView()
            }

            Spacer(minLength: 8)

            if case .finished(let packageID) = model.phase {
                if let client = jamf.client {
                    Link("View in Jamf Pro", destination: client.packageURL(id: packageID))
                        .buttonStyle(.glass)
                }
                Button("Done") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(model.isBusy ? "Stop Upload" : "Cancel") {
                    if model.isBusy {
                        model.cancel()
                    } else {
                        dismiss()
                    }
                }
                .buttonStyle(.glass)

                Button("Upload") {
                    Task { await upload() }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isConnectedToSelection || model.isBusy || !model.canUpload)
            }
        }
        .padding(16)
    }

    // MARK: Actions

    /// Opens Settings on the Jamf Pro tab. `openSettings()` on its own reopens
    /// whichever tab was last shown.
    private func showJamfSettings() {
        settingsNavigator.show(.jamfPro)
        openSettings()
    }

    private func connectIfPossible() async {
        guard let server = selectedServer else { return }
        if jamf.hasStoredSecret(for: server) {
            await jamf.switchTo(server)
            await refreshDuplicate()
        } else {
            jamf.disconnect()
        }
    }

    private func connect() async {
        guard let server = selectedServer else { return }
        await jamf.connect(to: server, secret: secret.isEmpty ? nil : secret)
        secret = ""
        await refreshDuplicate()
    }

    private func refreshDuplicate() async {
        guard let client = jamf.client, isConnectedToSelection else { return }
        await model.checkForDuplicate(using: client)
    }

    private func upload() async {
        guard let client = jamf.client else { return }
        await model.upload(using: client)
        if case .finished = model.phase {
            // Remember the metadata so the next build of this app starts from it.
            controller.rememberJamfMetadata(model.metadata)
        }
    }
}
