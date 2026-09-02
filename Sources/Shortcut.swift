import AppKit
import Carbon.HIToolbox

/// A global shortcut, stored as the Carbon key code and modifier mask the hotkey
/// API wants, so nothing has to be translated at registration time.
struct Shortcut: Equatable, Codable {
    var keyCode: UInt32
    var modifiers: UInt32          // Carbon: cmdKey, optionKey, shiftKey, controlKey

    static let none = Shortcut(keyCode: 0, modifiers: 0)
    var isSet: Bool { keyCode != 0 || modifiers != 0 }

    // MARK: Display

    var display: String {
        guard isSet else { return "—" }
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_Space: return String(localized: "Space")
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "esc"
        case kVK_Delete: return "⌫"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Slash: return "/"
        default: break
        }
        if let s = characters(for: code) { return s.uppercased() }
        return String(format: String(localized: "key %d"), locale: .current, code)
    }

    /// Ask the current keyboard layout what an unmodified press produces, so a
    /// French or Dvorak layout shows the key the user actually presses.
    private static func characters(for code: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &dead, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }

    // MARK: Capture

    /// Does this event press exactly this combination?
    func matches(_ event: NSEvent) -> Bool {
        guard isSet, UInt32(event.keyCode) == keyCode else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option)  { mods |= UInt32(optionKey) }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        return mods == modifiers
    }

    /// Build one from a key event, dropping presses that are only modifiers.
    static func from(event: NSEvent, allowingBareKey bare: Bool = false) -> Shortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option)  { mods |= UInt32(optionKey) }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        // A global shortcut with no modifier would swallow that key everywhere;
        // one scoped to an open note is fine without.
        guard mods != 0 || bare else { return nil }
        return Shortcut(keyCode: UInt32(event.keyCode), modifiers: mods)
    }
}
