import AppKit
import SwiftUI
import Observation
import NoiseAudio

// NSWorkspace supplies app identity without inspecting windows or intercepting clicks.
// A small key panel makes Noise active, so the next clicked app produces an activation.
@MainActor @Observable final class ApplicationPicker: NSObject, NSWindowDelegate {
    private(set) var currentApplication: ApplicationReference?
    private(set) var isPicking = false
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var hiddenWindows: [NSWindow] = []
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var onPick: ((ApplicationReference) -> Void)?

    override init() {
        super.init()
        currentApplication = Self.reference(NSWorkspace.shared.frontmostApplication)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.activated(app) }
        }
    }

    func begin(onPick: @escaping (ApplicationReference) -> Void) {
        cancel()
        self.onPick = onPick
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 155),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Select an application"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ApplicationPickPrompt { [weak self] in self?.cancel() })
        panel.delegate = self
        self.panel = panel
        if let screen = NSScreen.main {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.midX - 160, y: screen.visibleFrame.maxY - 70))
        } else { panel.center() }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        hiddenWindows = NSApp.windows.filter { $0 !== panel && $0.isVisible && $0.level == .normal && $0.title != "Select applications" }
        hiddenWindows.forEach { $0.orderOut(nil) }
        isPicking = true
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.cancel()
        }
    }

    func cancel() {
        isPicking = false
        onPick = nil
        deadline?.cancel(); deadline = nil
        let oldPanel = panel
        panel = nil
        oldPanel?.delegate = nil
        oldPanel?.close()
        hiddenWindows.forEach { $0.orderBack(nil) }
        if let window = hiddenWindows.first(where: { $0.canBecomeKey }) {
            if NSApp.isActive { window.makeKeyAndOrderFront(nil) }
            else { window.makeKey() }
        }
        hiddenWindows = []
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(); return false }

    private func activated(_ app: NSRunningApplication) {
        guard let reference = Self.reference(app) else { return }
        currentApplication = reference
        guard isPicking else { return }
        let completion = onPick
        cancel()
        completion?(reference)
    }

    private static func reference(_ app: NSRunningApplication?) -> ApplicationReference? {
        guard let app, app.activationPolicy == .regular, let id = app.bundleIdentifier,
              id != Bundle.main.bundleIdentifier else { return nil }
        return ApplicationReference(id: id, name: app.localizedName ?? id, bundleURL: app.bundleURL)
    }
}
