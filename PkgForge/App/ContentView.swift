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

        // The action bar sits outside the NavigationStack, so it spans the whole
        // window rather than the content column — with the inspector open the
        // column is barely wider than the buttons. It is a hard sibling rather
        // than a safe-area inset because an inset lets a scroll view render its
        // last row underneath the bar, and the inspector ignores it outright.
        VStack(spacing: 0) {
            NavigationStack {
                Group {
                    if let bundle = controller.bundle {
                        ConfigurationForm(bundle: bundle)
                    } else {
                        DropZoneView(isTargeted: isTargeted)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("PkgForge")
            .navigationSubtitle(controller.bundle.map { "\($0.onDiskName).app" } ?? "No application loaded")
            .toolbar {
                ToolbarItemGroup {
                    Button(controller.bundle == nil ? "Choose" : "Replace", systemImage: "folder") {
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
                .inspector(isPresented: $isLogShown) {
                    BuildLogView()
                        .inspectorColumnWidth(min: 300, ideal: 400, max: 700)
                }
            }

            Divider()
            actionBar
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
                .layoutPriority(0)
            Spacer(minLength: 12)
            // Fixed so the buttons keep their labels when the inspector narrows
            // the column — the filename beside them may truncate, "Upload to
            // Jamf Pro…" may not.
            HStack(spacing: 10) {
                actions
            }
            .fixedSize()
            .layoutPriority(1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    /// One line, always. The bar is only as wide as the content column, which
    /// halves when the inspector opens — a two-line status wraps into
    /// something unreadable long before the buttons run out of room.
    @ViewBuilder
    private var status: some View {
        switch controller.phase {
        case .empty:
            Text("Drop an application to begin.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)

        case .ready:
            if let output = controller.outputURL {
                HStack(spacing: 6) {
                    Text(output.lastPathComponent)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // Negative priority: this is the first thing to go when
                    // space runs short, and the least missed.
                    Text("· \(controller.selectedIdentity.map { "signing with \($0.shortName)" } ?? "unsigned")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
            }

        case .building(let fraction, let step):
            HStack(spacing: 10) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                Text(step)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }

        case .finished(let outcome):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(outcome.packageURL.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("· \(ByteCountFormatter.string(fromByteCount: outcome.byteCount, countStyle: .file)) · \(outcome.isSigned ? "signed" : "unsigned")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }

        case .failed(let message):
            HStack(spacing: 6) {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(message)
            }
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

            Button("Upload to Jamf Pro", systemImage: "arrow.up.circle") {
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
