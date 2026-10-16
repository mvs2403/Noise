import AppKit
import SwiftUI
import NoiseAudio

struct ApplicationChooserView: View {
    @Bindable var store: AudioStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<String>()
    @State private var known: [String: ApplicationReference] = [:]
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Select applications").font(.title2.weight(.semibold))
                Text("Selected apps share noise cancellation and voice leveling.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("Use current app") {
                    guard let app = store.appPicker.currentApplication else { return }
                    known[app.id] = app
                    selected.insert(app.id)
                }
                .disabled(store.appPicker.currentApplication == nil)
                .help(store.appPicker.currentApplication.map { "Add \($0.name)" } ?? "Switch to another app first")
                Button {
                    apply()
                    dismiss()
                    store.pickApplicationWindow()
                } label: { Label("Pick a window…", systemImage: "cursorarrow.click") }
            }
            if let app = store.appPicker.currentApplication {
                Text("Current app: \(app.name)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            TextField("Search applications", text: $search).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search applications")
            List {
                let usingAudio = choices.filter { activeIDs.contains($0.id) }
                let other = choices.filter { !activeIDs.contains($0.id) }
                if !usingAudio.isEmpty {
                    Section("Using audio") { ForEach(usingAudio) { row($0) } }
                }
                if !other.isEmpty {
                    Section("Applications") { ForEach(other) { row($0) } }
                }
                if choices.isEmpty { Text("No matching applications").foregroundStyle(.secondary) }
            }
            .listStyle(.inset)
            .frame(height: 245)
            Text("Browser selection includes audio across its tabs.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("\(selected.count) selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") { apply(); dismiss() }.keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 410)
        .onAppear {
            search = ""
            selected = store.appSelection.ids
            known = [:]
            rememberApplications()
        }
        .onChange(of: store.applications) { _, _ in rememberApplications() }
    }

    private var activeIDs: Set<String> { Set(store.applications.filter(\.isOutputActive).map(\.id)) }
    private var runningIDs: Set<String> { Set(store.applications.map(\.id)) }
    private var choices: [ApplicationReference] {
        known.values.filter { search.isEmpty || $0.name.localizedStandardContains(search) || $0.id.localizedStandardContains(search) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func row(_ app: ApplicationReference) -> some View {
        Toggle(isOn: Binding(get: { selected.contains(app.id) }, set: { enabled in
            if enabled { selected.insert(app.id) } else { selected.remove(app.id) }
        })) {
            HStack(spacing: 9) {
                if let url = app.bundleURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 24, height: 24)
                } else { Image(systemName: "app").frame(width: 24, height: 24) }
                Text(app.name).lineLimit(1)
                Spacer()
                if !runningIDs.contains(app.id) { Text("Not running").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 3)
        }
        .toggleStyle(.checkbox)
        .accessibilityLabel(app.name)
    }

    private func rememberApplications() {
        for app in store.appSelection.applications { known[app.id] = app }
        for app in store.applications { known[app.id] = app.reference }
        if let app = store.appPicker.currentApplication { known[app.id] = app }
    }

    private func apply() { store.selectApplications(known.values.filter { selected.contains($0.id) }) }
}
