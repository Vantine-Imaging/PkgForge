import SwiftUI

/// Live tool output (B-6). `pkgbuild` and `codesign` are streamed in as they
/// talk, not collected and dumped at the end.
struct BuildLogView: View {
    @Environment(BuildController.self) private var controller

    var body: some View {
        VStack(spacing: 0) {
            if controller.log.isEmpty {
                ContentUnavailableView(
                    "No output yet",
                    systemImage: "text.alignleft",
                    description: Text("Tool output appears here while the package builds.")
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(controller.log) { entry in
                                logRow(entry)
                                    .id(entry.id)
                            }
                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchor)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    }
                    .onChange(of: controller.log.count) {
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(bottomAnchor, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 280)
        .toolbar {
            ToolbarItem {
                Button("Copy Log", systemImage: "doc.on.doc") {
                    controller.copyLog()
                }
                .disabled(controller.log.isEmpty)
                .help("Copy the whole log to the clipboard")
            }
        }
    }

    private let bottomAnchor = "log-bottom"

    @ViewBuilder
    private func logRow(_ entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // Plain tool output gets no glyph — a column of dashes down the
            // side of a payload listing is noise, and the indent alone keeps
            // it distinguishable from PkgForge's own lines.
            Group {
                if let symbol = symbol(for: entry.kind) {
                    Image(systemName: symbol)
                        .font(.caption2)
                        .foregroundStyle(color(for: entry.kind))
                } else {
                    Color.clear
                }
            }
            .frame(width: 12)
            .padding(.top, 2)

            Text(entry.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color(for: entry.kind))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func symbol(for kind: LogEntry.Kind) -> String? {
        switch kind {
        case .info: "info.circle"
        case .command: "chevron.right"
        case .output: nil
        case .warning: "exclamationmark.triangle"
        case .failure: "xmark.octagon"
        case .success: "checkmark.circle"
        }
    }

    private func color(for kind: LogEntry.Kind) -> Color {
        switch kind {
        case .info: .secondary
        case .command: .accentColor
        case .output: .primary
        case .warning: .orange
        case .failure: .red
        case .success: .green
        }
    }
}
