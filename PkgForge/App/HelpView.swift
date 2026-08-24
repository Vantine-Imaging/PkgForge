import AppKit
import Observation
import SwiftUI

/// Lets the Help menu open the window on a specific topic.
@MainActor
@Observable
final class HelpNavigator {
    var selection: String = HelpBook.gettingStarted.id
}

struct HelpView: View {
    @Environment(HelpNavigator.self) private var navigator

    var body: some View {
        @Bindable var navigator = navigator

        NavigationSplitView {
            List(HelpBook.topics, selection: $navigator.selection) { topic in
                Label(topic.title, systemImage: topic.symbol)
                    .padding(.vertical, 2)
                    .tag(topic.id)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            let topic = HelpBook.topic(id: navigator.selection)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(topic.title)
                            .font(.largeTitle.weight(.semibold))
                        Text(topic.summary)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 4)

                    ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
                .textSelection(.enabled)
            }
            // No navigationTitle here on purpose: it would rename the window
            // itself, so the Window menu would list whichever topic happened to
            // be open instead of "PkgForge Help".
            //
            // A fresh topic should start at the top, not wherever the last one
            // was scrolled to.
            .id(topic.id)
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    @ViewBuilder
    private func blockView(_ block: HelpBlock) -> some View {
        switch block {
        case .heading(let text):
            Text(text)
                .font(.title3.weight(.semibold))
                .padding(.top, 8)

        case .paragraph(let text):
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("•").foregroundStyle(.tertiary)
                        Text(item)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .code(let text):
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.background.secondary, in: .rect(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }

        case .note(let text):
            callout(text, symbol: "info.circle.fill", tint: .accentColor)

        case .warning(let text):
            callout(text, symbol: "exclamationmark.triangle.fill", tint: .orange)
        }
    }

    private func callout(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .padding(.top, 2)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: .rect(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 0.5)
        }
    }
}
