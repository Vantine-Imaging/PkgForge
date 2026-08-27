// Copyright 2026 Vantine Imaging LLC
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UniformTypeIdentifiers

/// The empty state: one big target for a `.app` (I-1, I-3).
struct DropZoneView: View {
    @Environment(BuildController.self) private var controller

    let isTargeted: Bool

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.quaternary.opacity(isTargeted ? 0.55 : 0.18))
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(
                        isTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary),
                        style: StrokeStyle(lineWidth: isTargeted ? 2.5 : 1.5, dash: [9, 7])
                    )

                VStack(spacing: 14) {
                    Image(systemName: isTargeted ? "square.and.arrow.down.fill" : "shippingbox")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(isTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                        .symbolEffect(.bounce, value: isTargeted)

                    Text(isTargeted ? "Release to load" : "Drop an application here")
                        .font(.title2.weight(.medium))

                    Text("PkgForge reads the bundle, writes the cleanup scripts,\nand builds a signed installer package.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button("Choose") { controller.chooseFile() }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .padding(.top, 4)
                }
                .padding(40)
            }
            .frame(maxWidth: 560, minHeight: 340)
            .animation(.smooth(duration: 0.18), value: isTargeted)

            if let error = controller.inputError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}
