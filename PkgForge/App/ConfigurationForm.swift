import SwiftUI

/// The prefilled, fully editable form (section 4).
struct ConfigurationForm: View {
    @Environment(BuildController.self) private var controller

    let bundle: AppBundle

    var body: some View {
        @Bindable var controller = controller

        Form {
            Section {
                BundleSummaryRow(bundle: bundle)
            }

            if let error = controller.inputError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            if let saved = controller.loadedProfileDate {
                Section {
                    Label {
                        Text("Prefilled from the profile saved \(saved.formatted(date: .abbreviated, time: .shortened)). Only the version came from the new bundle.")
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Package") {
                LabeledContent("Identifier") {
                    TextField("Identifier", text: $controller.configuration.identifier)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .labelsHidden()
                }
                LabeledContent("Version") {
                    TextField("Version", text: $controller.configuration.version)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                LabeledContent("Install Location") {
                    TextField("Install Location", text: $controller.configuration.installLocation)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .labelsHidden()
                }
            }

            Section("Signing & Output") {
                Picker("Installer Identity", selection: $controller.configuration.signingIdentitySHA1) {
                    Text("Don't sign").tag(String?.none)
                    if !controller.installerIdentities.isEmpty {
                        Divider()
                        ForEach(controller.installerIdentities) { identity in
                            Text(identity.shortName).tag(String?.some(identity.sha1))
                        }
                    }
                }

                if controller.installerIdentities.isEmpty {
                    Label(
                        "No Developer ID Installer identities in your keychain. Only installer identities can sign a package — an application identity produces one macOS refuses to install.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                LabeledContent("Output Folder") {
                    HStack(spacing: 8) {
                        Text(controller.configuration.outputDirectory.path(percentEncoded: false))
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…") { controller.chooseOutputDirectory() }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                }

                if let output = controller.outputURL {
                    LabeledContent("Filename") {
                        Text(output.lastPathComponent)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                LabeledContent("Quit Timeout") {
                    HStack(spacing: 8) {
                        TextField(
                            "Seconds",
                            value: $controller.configuration.quitTimeout,
                            format: .number
                        )
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 70)
                        Stepper("Seconds", value: $controller.configuration.quitTimeout, in: 0...600)
                            .labelsHidden()
                        Text("seconds")
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $controller.configuration.abortIfRunning) {
                    Text("Abort the install if the app cannot be stopped")
                    Text("Half-replacing a bundle that is still mapped into a running process is worse than failing the policy.")
                }

                Toggle(isOn: $controller.configuration.preventRelocation) {
                    Text("Always install to the location above")
                    Text("Off lets the installer redirect the payload to wherever a copy of this bundle identifier already exists — a user's ~/Applications, another volume. Leave it on for managed deployments.")
                }
                .help("Sets BundleIsRelocatable to false for every component in the payload.")

                Toggle(isOn: $controller.configuration.removeStrayCopies) {
                    Text("Remove stray copies found elsewhere on disk")
                    Text("Searches /Applications and each user's ~/Applications, two levels deep.")
                }
            } header: {
                Text("On Install")
            }

            Section {
                PathListEditor(
                    title: "Root-level paths",
                    caption: "One absolute path per line, deleted before the new bundle is written. LaunchDaemons and LaunchAgents listed here are unloaded first.",
                    text: $controller.configuration.rootStalePaths,
                    placeholder: "/Library/Application Support/${APP_NAME}\n/Library/LaunchDaemons/${BUNDLE_ID}.helper.plist"
                )

                PathListEditor(
                    title: "Per-user paths",
                    caption: "Relative to each home directory under /Users. Shared, Guest and dot-directories are skipped.",
                    text: $controller.configuration.userStalePaths,
                    placeholder: PackageConfiguration.defaultUserStalePaths
                )

                Label(
                    "${BUNDLE_ID} and ${APP_NAME} are substituted when the scripts are generated.",
                    systemImage: "curlybraces"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Text("Stale Path Cleanup")
            }

            Section {
                Picker(
                    "Preinstall additions run",
                    selection: $controller.configuration.customPreinstallPlacement
                ) {
                    ForEach(ScriptFragmentPlacement.allCases) { placement in
                        Text(placement.label).tag(placement)
                    }
                }
                .disabled(!controller.configuration.hasCustomPreinstall)

                PathListEditor(
                    title: "Preinstall additions",
                    caption: "Bash spliced into the generated preinstall. $APP_NAME, $BUNDLE_ID, $APP_PATH, $INSTALL_LOCATION, $CONSOLE_USER, $CONSOLE_UID and log() are all in scope.",
                    text: $controller.configuration.customPreinstall,
                    placeholder: "/usr/bin/defaults delete \"$BUNDLE_ID\" LastSeenVersion",
                    unit: "line",
                    minHeight: 72
                )

                PathListEditor(
                    title: "Postinstall additions",
                    caption: "Runs after ownership, permissions and quarantine are corrected, before the signature check.",
                    text: $controller.configuration.customPostinstall,
                    placeholder: "/bin/launchctl bootstrap system /Library/LaunchDaemons/$BUNDLE_ID.helper.plist",
                    unit: "line",
                    minHeight: 72
                )

                extraFiles
            } header: {
                Text("Additional Scripts")
            } footer: {
                Text("A flat package declares exactly two script phases, preinstall and postinstall — the legacy preflight, postflight, preupgrade and postupgrade phases belong to pre-10.5 bundle packages and are never run. So anything extra goes inside those two scripts. PkgForge runs bash -n over the finished scripts and fails the build rather than shipping one that breaks at install time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !controller.diagnostics.isEmpty {
                Section("Check These") {
                    ForEach(controller.diagnostics) { diagnostic in
                        Label {
                            Text(diagnostic.message)
                                .foregroundStyle(diagnostic.severity == .error ? Color.red : Color.primary)
                        } icon: {
                            Image(systemName: diagnostic.severity == .error
                                  ? "exclamationmark.octagon.fill"
                                  : "exclamationmark.triangle.fill")
                            .foregroundStyle(diagnostic.severity == .error ? Color.red : Color.orange)
                        }
                        .font(.callout)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Files archived into the package's Scripts directory alongside the two
    /// generated scripts.
    @ViewBuilder
    private var extraFiles: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Bundled files").font(.callout.weight(.medium))
                Spacer()
                Button("Add…") { controller.addExtraScriptFiles() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }

            if controller.configuration.extraScriptFiles.isEmpty {
                Text("None.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(controller.configuration.extraScriptFiles, id: \.self) { path in
                        let url = URL(fileURLWithPath: path)
                        HStack(spacing: 8) {
                            Image(systemName: FileManager.default.fileExists(atPath: path)
                                  ? "doc.plaintext" : "exclamationmark.triangle.fill")
                            .foregroundStyle(FileManager.default.fileExists(atPath: path)
                                             ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))

                            Text(url.lastPathComponent)
                                .font(.callout.monospaced())
                                .lineLimit(1)

                            Text(url.deletingLastPathComponent().path(percentEncoded: false))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.head)

                            Spacer(minLength: 4)

                            Button("Remove", systemImage: "minus.circle") {
                                controller.removeExtraScriptFile(path)
                            }
                            .buttonStyle(.borderless)
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .background(.background, in: .rect(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 0.5)
                }
            }

            Text("Copied into the package's Scripts directory. macOS never runs them itself — call them from your additions above as \"$(/usr/bin/dirname \"$0\")/name\". Anything starting with #! gets mode 755, everything else 644.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// A multi-line path editor. `TextEditor` rather than a list: these get pasted
/// in from notes and scripts, and editing them as text is the point.
struct PathListEditor: View {
    let title: String
    let caption: String
    @Binding var text: String
    let placeholder: String
    var unit: String = "path"
    var minHeight: CGFloat = 84

    private var lineCount: Int {
        text.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Text(lineCount == 1 ? "1 \(unit)" : "\(lineCount) \(unit)s")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.callout.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(6)

                if text.isEmpty {
                    Text(placeholder)
                        .font(.callout.monospaced())
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: minHeight)
            .background(.background, in: .rect(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
