import Foundation
import ServiceManagement

/// Thin UserDefaults wrapper for the handful of togglable preferences.
enum Settings {
    private static let d = UserDefaults.standard

    static var showOverFullScreen: Bool {
        get { d.object(forKey: "showOverFullScreen") as? Bool ?? false }
        set { d.set(newValue, forKey: "showOverFullScreen") }
    }

    static var deckOnLeftEdge: Bool {
        get { d.bool(forKey: "deckOnLeftEdge") }
        set { d.set(newValue, forKey: "deckOnLeftEdge") }
    }

    /// Vertical position of the pill along the screen edge (0.0 = bottom, 1.0 = top).
    static var deckYRatio: CGFloat {
        get {
            if let hit = cachedYRatio { return hit }
            let v = (d.object(forKey: "deckYRatio") as? CGFloat).map { min(max($0, 0.0), 1.0) } ?? 0.5
            cachedYRatio = v
            return v
        }
        set {
            let v = min(max(newValue, 0.0), 1.0)
            cachedYRatio = v
            d.set(v, forKey: "deckYRatio")
        }
    }
    private static var cachedYRatio: CGFloat?

    /// Target display: "all" for all screens, "main" for primary, or "id:<displayID>".
    static var displayTarget: String {
        get { d.string(forKey: "displayTarget") ?? "all" }
        set { d.set(newValue, forKey: "displayTarget") }
    }

    /// Max tabs the fan shows before collapsing the remainder into "+N".
    /// Five keeps every tab at full size instead of squeezing the deck.
    static let fanLimit = 5

    /// Body text size inside a note.
    static let fontSizes: [(name: String, size: Double)] = [
        ("Small", 12), ("Medium", 13.5), ("Large", 15.5), ("Extra Large", 18)
    ]

    static let fontRange: ClosedRange<Double> = 10...30

    static var noteFontSize: Double {
        get {
            let v = d.double(forKey: "noteFontSize")
            return fontRange.contains(v) ? v : 13.5
        }
        set { d.set(min(max(newValue, fontRange.lowerBound), fontRange.upperBound),
                    forKey: "noteFontSize") }
    }

    /// PostScript name of the face note bodies are set in; empty means the
    /// system font. Defaults to a hand, the way a sticky note actually looks.
    static var noteFontName: String {
        get {
            if let v = d.string(forKey: "noteFontName") { return v }
            // migrate the old boolean
            let hand = d.object(forKey: "handwrittenBody") as? Bool ?? true
            return hand ? "Noteworthy-Light" : ""
        }
        set { d.set(newValue, forKey: "noteFontName") }
    }

    // MARK: Shortcuts

    private static func shortcut(_ key: String, default def: Shortcut) -> Shortcut {
        guard let data = d.data(forKey: key),
              let s = try? JSONDecoder().decode(Shortcut.self, from: data) else { return def }
        return s
    }
    private static func setShortcut(_ key: String, _ value: Shortcut) {
        d.set(try? JSONEncoder().encode(value), forKey: key)
    }

    /// ⌥⌘N, ⌥⌘A, ⌥⌘L out of the box.
    static var scNewNote: Shortcut {
        get { shortcut("scNewNote", default: Shortcut(keyCode: 45, modifiers: 2048 | 256)) }
        set { setShortcut("scNewNote", newValue) }
    }
    static var scAllNotes: Shortcut {
        get { shortcut("scAllNotes", default: Shortcut(keyCode: 0, modifiers: 2048 | 256)) }
        set { setShortcut("scAllNotes", newValue) }
    }
    static var scCapture: Shortcut {
        get { shortcut("scCapture", default: Shortcut(keyCode: 49, modifiers: 512 | 256)) }  // ⇧⌘Space
        set { setShortcut("scCapture", newValue) }
    }
    static var scArchive: Shortcut {
        get { shortcut("scArchive", default: Shortcut(keyCode: 37, modifiers: 2048 | 256)) }
        set { setShortcut("scArchive", newValue) }
    }

    // In-note shortcuts. These are matched by the open note itself rather than
    // registered globally, so a bare key like esc is safe here.
    private static let cmd: UInt32 = 256, shift: UInt32 = 512
    private static let opt: UInt32 = 2048, ctrl: UInt32 = 4096

    static var scArchiveNote: Shortcut {
        get { shortcut("scArchiveNote", default: Shortcut(keyCode: 0,  modifiers: shift | cmd)) }
        set { setShortcut("scArchiveNote", newValue) }
    }
    static var scClose: Shortcut {
        get { shortcut("scClose",       default: Shortcut(keyCode: 53, modifiers: 0)) }
        set { setShortcut("scClose", newValue) }
    }
    static var scFind: Shortcut {
        get { shortcut("scFind",        default: Shortcut(keyCode: 3,  modifiers: cmd)) }
        set { setShortcut("scFind", newValue) }
    }
    static var scTask: Shortcut {
        get { shortcut("scTask",        default: Shortcut(keyCode: 17, modifiers: cmd)) }
        set { setShortcut("scTask", newValue) }
    }
    static var scPin: Shortcut {
        get { shortcut("scPin",         default: Shortcut(keyCode: 35, modifiers: cmd)) }
        set { setShortcut("scPin", newValue) }
    }
    static var scColour: Shortcut {
        get { shortcut("scColour",      default: Shortcut(keyCode: 47, modifiers: cmd)) }
        set { setShortcut("scColour", newValue) }
    }
    static var scDelete: Shortcut {
        get { shortcut("scDelete",      default: Shortcut(keyCode: 51, modifiers: cmd)) }
        set { setShortcut("scDelete", newValue) }
    }
    static var scBigger: Shortcut {
        get { shortcut("scBigger",      default: Shortcut(keyCode: 24, modifiers: ctrl)) }
        set { setShortcut("scBigger", newValue) }
    }
    static var scSmaller: Shortcut {
        get { shortcut("scSmaller",     default: Shortcut(keyCode: 27, modifiers: ctrl)) }
        set { setShortcut("scSmaller", newValue) }
    }

    // MARK: Deck

    /// How far from the screen edge the deck notices the pointer. A wider strip
    /// is easier to hit; a narrower one stays further out of the way.
    static let edgeWidths: [(name: String, width: Double)] = [
        ("Narrow", 8), ("Standard", 14), ("Wide", 28), ("Very wide", 44)
    ]

    static var edgeWidth: Double {
        get {
            let v = d.double(forKey: "edgeWidth")
            return v >= 4 ? v : 14
        }
        set { d.set(newValue, forKey: "edgeWidth") }
    }

    // A short list of note sizes. Dragging a corner meant re-laying out a window
    // and a text view on every pointer move; picking from four does it once.
    static let noteSizes: [(name: String, size: CGSize)] = [
        ("Small",  CGSize(width: 400, height: 320)),
        ("Medium", CGSize(width: 460, height: 380)),
        ("Large",  CGSize(width: 560, height: 470)),
        ("Huge",   CGSize(width: 680, height: 560)),
    ]

    static var noteSizeIndex: Int {
        get {
            if let hit = cachedNoteSizeIndex { return hit }
            let v: Int
            if let stored = d.object(forKey: "noteSizeIndex") as? Int,
               noteSizes.indices.contains(stored) {
                v = stored
            } else if case let w = d.double(forKey: "noteWidth"), w > 0 {
                // Carry over a size that was previously dragged: pick the nearest.
                v = noteSizes.enumerated()
                    .min { abs($0.element.size.width - w) < abs($1.element.size.width - w) }?
                    .offset ?? 1
            } else {
                v = 1
            }
            cachedNoteSizeIndex = v
            return v
        }
        set {
            let v = min(max(newValue, 0), noteSizes.count - 1)
            cachedNoteSizeIndex = v
            d.set(v, forKey: "noteSizeIndex")
        }
    }
    private static var cachedNoteSizeIndex: Int?

    static var noteSize: CGSize { noteSizes[noteSizeIndex].size }

    /// Open a note by hovering its tab instead of clicking it. Off by default:
    /// the deck is meant to stay quiet until you ask it for something.
    static var openOnHover: Bool {
        get { d.object(forKey: "openOnHover") as? Bool ?? false }
        set { d.set(newValue, forKey: "openOnHover") }
    }

    /// How long the pointer must rest on a tab before it opens, so sweeping past
    /// the deck does not open every note in turn.
    static let openOnHoverDelay: TimeInterval = 0.4

    /// Show a lightweight peek / flyout preview card when hovering a tab.
    static var tabPreview: Bool {
        get { d.object(forKey: "tabPreview") as? Bool ?? true }
        set { d.set(newValue, forKey: "tabPreview") }
    }

    /// How long the pointer must rest on a tab before its preview card appears.
    static let tabPreviewDelay: TimeInterval = 0.18

    /// Style Markdown inline — headings, emphasis, code, quotes.
    static var markdownStyling: Bool {
        get { d.object(forKey: "markdownStyling") as? Bool ?? true }
        set { d.set(newValue, forKey: "markdownStyling") }
    }

    /// How long the deck may sit untouched before it tidies itself away.
    static let fanIdleTimeout: TimeInterval = 4
    static let noteIdleTimeout: TimeInterval = 60

    /// Keep the deck fanned out instead of letting it fall back to the pill.
    /// Only the *resting* state changes — notes still open and tidy away as usual.
    static var deckAlwaysShown: Bool {
        get { d.bool(forKey: "deckAlwaysShown") }
        set { d.set(newValue, forKey: "deckAlwaysShown") }
    }

    /// Multiplier on every deck metric — tab width, label type, the lap between
    /// tabs, the chips and the pill. One knob so the deck scales as a whole
    /// instead of drifting out of proportion with itself.
    static let deckScaleRange: ClosedRange<Double> = 0.7...1.8

    static let deckSizes: [(name: String, scale: Double)] = [
        ("Small", 0.85), ("Default", 1.0), ("Large", 1.25), ("Extra large", 1.5)
    ]

    /// Memoized: DeckGeom routes every metric through this, and SwiftUI reads
    /// those metrics dozens of times per body evaluation during the fan and drag
    /// animations. A UserDefaults read is a lock and a dictionary lookup (~320 ns
    /// measured); a stored static is free. All writes come through this setter
    /// and everything runs on the main thread, so the cache cannot go stale.
    static var deckScale: Double {
        get {
            if let hit = cachedDeckScale { return hit }
            let raw = d.double(forKey: "deckScale")
            let v = deckScaleRange.contains(raw) ? raw : 1.0
            cachedDeckScale = v
            return v
        }
        set {
            let v = min(max(newValue, deckScaleRange.lowerBound), deckScaleRange.upperBound)
            cachedDeckScale = v
            d.set(v, forKey: "deckScale")
        }
    }
    private static var cachedDeckScale: Double?

    /// Labelled tabs, or bare colour chips that barely touch the screen.
    static var deckStyle: DeckStyle {
        get { DeckStyle(rawValue: d.string(forKey: "deckStyle") ?? "") ?? .tabs }
        set { d.set(newValue.rawValue, forKey: "deckStyle") }
    }

    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Noty: launch-at-login toggle failed — \(error.localizedDescription)")
            }
        }
    }
}
