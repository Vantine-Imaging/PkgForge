import AppKit
import SwiftUI

/// What PkgForge read out of the bundle (M-2, M-5, M-6).
///
/// Lives as the first row of the form rather than pinned above it: pinning left
/// half-scrolled rows floating underneath it, and cost height that the form
/// needs more.
struct BundleSummaryRow: View {
    @Environment(BuildController.self) private var controller

    let bundle: AppBundle

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            AppIconView(url: bundle.url)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(bundle.displayName)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    if bundle.displayName != bundle.onDiskName {
                        Text("\(bundle.onDiskName).app")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help("The on-disk filename. The generated scripts key off this, not the display name.")
                    }
                }

                Text(bundle.bundleIdentifier)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                chips

                badges
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 6) {
                Button("Replace") { controller.chooseFile() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                Button("Remove") { controller.clear() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
        }
        .padding(.vertical, 6)
    }

    // MARK: Chips

    private var chipViews: [AnyView] {
        var views: [AnyView] = [AnyView(metadataChip("Version", bundle.preferredVersion))]
        if !bundle.buildVersion.isEmpty, bundle.buildVersion != bundle.preferredVersion {
            views.append(AnyView(metadataChip("Build", bundle.buildVersion)))
        }
        if let minimum = bundle.minimumSystemVersion {
            views.append(AnyView(metadataChip("Requires", "macOS \(minimum)")))
        }
        return views
    }

    /// Falls back to stacked rows rather than letting a chip wrap mid-word when
    /// the inspector narrows the column.
    private var chips: some View {
        let all = chipViews
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { ForEach(all.indices, id: \.self) { all[$0] } }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) { ForEach(all.prefix(2).indices, id: \.self) { all[$0] } }
                if all.count > 2 {
                    HStack(spacing: 8) { ForEach(2..<all.count, id: \.self) { all[$0] } }
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(all.indices, id: \.self) { all[$0] }
            }
        }
    }

    private func metadataChip(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.primary)
        }
        .font(.caption)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.4), in: .capsule)
    }

    // MARK: Badges

    private var badges: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                signatureBadge
                sizeBadge
            }
            VStack(alignment: .leading, spacing: 4) {
                signatureBadge
                sizeBadge
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var signatureBadge: some View {
        if let signature = controller.signature {
            Label {
                Text(signature.isSigned ? (signature.authority ?? "Signed") : "Unsigned")
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: signature.isSigned ? "checkmark.seal.fill" : "seal")
            }
            .font(.caption)
            .foregroundStyle(signature.isSigned ? Color.green : Color.secondary)
            .help(signature.detail.isEmpty ? "No signing information." : signature.detail)
        } else {
            Label("Checking signature…", systemImage: "seal")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var sizeBadge: some View {
        if let stats = controller.stats {
            Label("\(stats.formattedSize) · \(stats.fileCount.formatted()) files", systemImage: "internaldrive")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        } else if controller.isMeasuring {
            Label("Measuring…", systemImage: "internaldrive")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
    }
}

struct AppIconView: View {
    let url: URL
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.quaternary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: url) {
            let path = url.path(percentEncoded: false)
            icon = await Task.detached { NSWorkspace.shared.icon(forFile: path) }.value
        }
    }
}
