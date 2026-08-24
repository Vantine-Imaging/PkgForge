import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(BuildController.self) private var controller
    @Environment(JamfSession.self) private var jamf

    @State private var isTargeted = false
    @State private var isLogShown = false
    @State private var scriptPreview: ScriptPreviewPayload?
    @State private var isUploadShown = false

    var body: some View {
        @Bindable var controller = controller

        NavigationStack {
            // The action bar is a hard sibling of the content rather than a
            // safe-area inset: an inset lets a scroll view render its last row
            // underneath the bar, and the inspector ignored it outright.
            VStack(spacing: 0) {
                Group {
                    if let bundle = controller.bundle {
                        ConfigurationForm(bundle: bundle)
                    } else {
                        DropZoneView(isTargeted: isTargeted)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                actionBar
            }
            .navigationTitle("PkgForge")
            .navigationSubtitle(controller.bundle.map { "\($0.onDiskName).app" } ?? "No application loaded")
            .toolbar {
                ToolbarItemGroup {
                    Button(controller.bundle == nil ? "Choose…" : "Replace…", systemImage: "folder") {
                        controller.chooseFile()
                    }
                    .help("Choose an application bundle")

                    Button("Preview Scripts", systemImage: "doc.text.magnifyingglass") {
                        if let scripts = controller.previewScripts() {
                            scriptPreview = ScriptPreviewPayload(
                                preinstall: scripts.preinstall,
                                postinstall: scripts.postinstall
                            )
                        }
                    }
                    .disabled(controller.bundle == nil)
                    .help("Read the preinstall and postinstall scripts before building")
                }

                ToolbarItem {
                    Button("Build Log", systemImage: "sidebar.right") {
                        isLogShown.toggle()
                    }
                    .help("Show the build log")
                }
            }
            // Attached to the VStack so the inspector is a full-height column
            // beside the bar, not a pane that scrolls behind it.
            .inspector(isPresented: $isLogShown) {
                BuildLogView()
                    .inspectorColumnWidth(min: 300, ideal: 400, max: 700)
            }
        }
        // I-1 / I-4 — the whole window is the target, and a replacement is
        // accepted at any point, including mid-form.
        .dropDestination(for: URL.self) { urls, _ in
            guard let first = urls.first else { return false }
            controller.accept(url: first)
            if urls.count > 1 {
                controller.inputError = "Several items were dropped. PkgForge loaded \(first.lastPathComponent) and ignored the rest."
            }
            return true
        } isTargeted: { targeting in
            isTargeted = targeting
        }
        .sheet(item: $scriptPreview) { payload in
            ScriptPreviewSheet(preinstall: payload.preinstall, postinstall: payload.postinstall)
        }
        .sheet(isPresented: $isUploadShown) {
            JamfUploadSheet()
        }
        .alert(
            "A package with that name is already there",
            isPresented: Binding(
                get: { controller.pendingOverwrite != nil },
                set: { if !$0 { controller.pendingOverwrite = nil } }
            )
        ) {
            Button("Replace", role: .destructive) { controller.confirmOverwrite() }
            Button("Cancel", role: .cancel) { controller.pendingOverwrite = nil }
        } message: {
            if let url = controller.pendingOverwrite {
                Text("\(url.lastPathComponent) already exists in \(url.deletingLastPathComponent().lastPathComponent). Building will overwrite it.")
            }
        }
    }

    // MARK: - Bottom bar

    private var actionBar: some View {
        HStack(spacing: 14) {
            status
            Spacer(minLength: 12)
            actions
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    @ViewBuilder
    private var status: some View {
        switch controller.phase {
        case .empty:
            Text("Drop an application to begin.")
                .font(.callout)
                .foregroundStyle(.secondary)

        case .ready:
            if let output = controller.outputURL {
                VStack(alignment: .leading, spacing: 2) {
                    Text(output.lastPathComponent)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(controller.selectedIdentity.map { "Signing with \($0.shortName)" } ?? "Unsigned package")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

        case .building(let fraction, let step):
            HStack(spacing: 12) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 160)
                Text(step)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

        case .finished(let outcome):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(outcome.packageURL.lastPathComponent)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(ByteCountFormatter.string(fromByteCount: outcome.byteCount, countStyle: .file)) · \(outcome.isSigned ? "signed" : "unsigned")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

        case .failed(let message):
            Label {
                Text(message)
                    .font(.callout)
                    .lineLimit(2)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
            .frame(maxWidth: 420, alignment: .leading)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch controller.phase {
        case .building:
            Button("Cancel") { controller.cancelBuild() }
                .buttonStyle(.glass)
                .controlSize(.large)

        case .finished:
            Button("Reveal", systemImage: "folder") { controller.revealPackage() }
                .buttonStyle(.glass)
            Menu {
                Button("Copy Install Command") { controller.copyInstallCommand() }
                Button("Show Build Log") { isLogShown = true }
                Divider()
                Button("Build Again") { controller.startBuild() }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button("Upload to Jamf Pro…", systemImage: "arrow.up.circle") {
                isUploadShown = true
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)

        case .failed:
            Button("Copy Log") { controller.copyLog() }
                .buttonStyle(.glass)
            Button("Build") { controller.startBuild() }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(!controller.canBuild)

        case .empty, .ready:
            Button("Build Package") { controller.startBuild() }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!controller.canBuild)
        }
    }
}

struct ScriptPreviewPayload: Identifiable {
    let id = UUID()
    let preinstall: String
    let postinstall: String
}
