import SwiftUI

struct ApplicationPickPrompt: View {
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Click an app window", systemImage: "cursorarrow.click")
                .font(.headline)
            Text("Click its window or Dock icon to add the app. Your other selections stay selected.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text("Selection ends after 30 seconds.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            }
        }.padding(18).frame(width: 320)
    }
}
