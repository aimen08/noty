import AppKit

enum AppWindows {
    /// Keep the Dock and menu bar while any normal workspace window remains.
    /// The borderless deck does not need a Dock entry of its own.
    static func didClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        DispatchQueue.main.async {
            let hasWorkspace = NSApp.windows.contains {
                $0 !== closing && ($0.isVisible || $0.isMiniaturized) && $0.styleMask.contains(.titled)
            }
            NSApp.setActivationPolicy(hasWorkspace ? .regular : .accessory)
        }
    }
}
