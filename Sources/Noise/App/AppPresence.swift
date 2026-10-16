import AppKit

/// Menu-bar controls are the normal way back into Noise. If they are hidden,
/// keep a Dock icon so the running app always has a visible entry point.
@MainActor enum AppPresence {
    static func update(showMenuBar: Bool) {
        let policy: NSApplication.ActivationPolicy = showMenuBar ? .accessory : .regular
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }
}
