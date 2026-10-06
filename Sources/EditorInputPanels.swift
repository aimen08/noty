import AppKit

/// The character viewer and IME candidates live in system helper processes.
/// Their clicks are delivered to a global mouse monitor just like clicks in
/// another app, although they are part of editing the current note.
enum EditorInputPanels {
    struct Window {
        let bounds: CGRect
        let bundleID: String
        let alpha: Double
    }

    static func isInputHelper(_ bundleID: String) -> Bool {
        bundleID == "com.apple.CharacterPaletteIM"
            || bundleID == "com.apple.TextInputMenuAgent"
            || bundleID == "com.apple.TextInputUI.xpc.TextInputUIService"
            || bundleID.hasPrefix("com.apple.inputmethod.")
    }

    static func containsInputClick(targetBundleID: String?, at point: CGPoint, windows: [Window]) -> Bool {
        if let targetBundleID, isInputHelper(targetBundleID) { return true }
        // Windows arrive front to back. A covered input panel must not turn a
        // real click in the foreground app into an editing interaction.
        guard let hit = windows.first(where: { $0.alpha > 0 && $0.bounds.contains(point) }) else { return false }
        return isInputHelper(hit.bundleID)
    }

    static func isInputClick(_ event: NSEvent) -> Bool {
        let pid = event.cgEvent.map { pid_t($0.getIntegerValueField(.eventTargetUnixProcessID)) } ?? 0
        let target = pid > 0 ? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier : nil
        if let target, isInputHelper(target) { return true }
        // CGEvent coordinates already use Quartz's global top-left origin,
        // including displays to the left/above the primary screen.
        let point = event.cgEvent?.location ?? CGPoint(
            x: NSEvent.mouseLocation.x,
            y: CGDisplayBounds(CGMainDisplayID()).height - NSEvent.mouseLocation.y)
        return containsInputClick(targetBundleID: target, at: point, windows: visibleWindows())
    }

    static var isVisible: Bool { visibleWindows().contains { isInputHelper($0.bundleID) && $0.alpha > 0 } }

    private static func visibleWindows() -> [Window] {
        // Metadata only: no window images, titles, AX access or extra permission.
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        var identifiers: [pid_t: String] = [:]
        return rows.compactMap { row in
            guard let owner = row[kCGWindowOwnerPID as String] as? NSNumber,
                  let raw = row[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary),
                  bounds.width > 0, bounds.height > 0 else { return nil }
            let pid = pid_t(owner.int32Value)
            // Ignore our nonactivating, partly transparent edge panel.
            guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }
            let bundleID = identifiers[pid] ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            identifiers[pid] = bundleID
            return Window(bounds: bounds, bundleID: bundleID,
                          alpha: (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1)
        }
    }
}
