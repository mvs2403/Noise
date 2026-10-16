import AppKit
import SwiftUI

@main struct NoiseApp: App {
    @NSApplicationDelegateAdaptor(NoiseAppDelegate.self) private var appDelegate
    @State private var store = AudioStore.shared
    var body: some Scene {
        WindowGroup("Noise", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 820, minHeight: 700)
        }
        .defaultSize(width: 880, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Stop All Filtering") { Task { await store.stopAll() } }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                    .disabled(!store.canStop)
            }
        }
        MenuBarExtra("Noise", systemImage: store.anyRunning ? "waveform.circle.fill" : "waveform.circle",
                     isInserted: Binding(get: { store.showMenuBar }, set: { store.showMenuBar = $0 })) {
            MenuBarPanel(store: store)
        }
        .menuBarExtraStyle(.window)
        Window("Select applications", id: "applications") {
            ApplicationChooserView(store: store)
                .id(store.applicationChooserSession)
        }
        .windowResizability(.contentSize)
        Settings { SettingsView(store: store) }
    }
}

@MainActor final class NoiseAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPresence.update(showMenuBar: AudioStore.shared.showMenuBar)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The menu-bar controls and audio routes outlive their windows.
        false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            AudioStore.shared.appPicker.cancel()
            await AudioStore.shared.stopAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
