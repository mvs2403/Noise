import AppKit
import SwiftUI

struct ApplicationSelectionButton: View {
    let store: AudioStore
    var expanded = false
    var didOpen: (() -> Void)?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            store.prepareApplicationChooser()
            didOpen?()
            openWindow(id: "applications")
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            HStack(spacing: 6) {
                if expanded { Image(systemName: "app.badge.checkmark").foregroundStyle(.tint) }
                Text(store.appSelection.summary).lineLimit(1).truncationMode(.tail)
                if expanded { Spacer(minLength: 4) }
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: expanded ? .infinity : nil, minHeight: expanded ? 36 : nil, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Select applications")
        .accessibilityValue(store.appSelection.summary)
        .help("Choose which applications to filter")
    }
}
