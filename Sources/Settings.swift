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

    /// Max tabs the fan shows before collapsing the remainder into "+N".
    /// Five keeps every tab at full size instead of squeezing the deck.
    static let fanLimit = 5

    /// Body text size inside a note.
    static let fontSizes: [(name: String, size: Double)] = [
        ("Маленький", 12), ("Средний", 13.5), ("Большой", 15.5), ("Очень большой", 18)
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

    /// How long the deck may sit untouched before it tidies itself away.
    static let fanIdleTimeout: TimeInterval = 4
    static let noteIdleTimeout: TimeInterval = 60

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
