import AppKit
import SwiftUI

/// Shows the scripts that will ship inside the package, before building. What
/// runs as root on every managed Mac is worth reading once.
struct ScriptPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let preinstall: String
    let postinstall: String

    @State private var selection: Script = .preinstall

    enum Script: String, CaseIterable, Identifiable {
        case preinstall, postinstall
        var id: String { rawValue }
        var title: String { rawValue }
    }

    private var body_: String {
        selection == .preinstall ? preinstall : postinstall
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Script", selection: $selection) {
                ForEach(Script.allCases) { script in
                    Text(script.title).tag(script)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            ScrollView([.vertical, .horizontal]) {
                Text(body_)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.background)

            Divider()

            HStack {
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(body_, forType: .string)
                }
                .buttonStyle(.glass)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 720, height: 560)
    }
}
