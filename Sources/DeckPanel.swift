import AppKit
import SwiftUI

// MARK: - Geometry

/// How the deck draws itself once it fans out.
enum DeckStyle: String, CaseIterable {
    case tabs      // labelled vertical tabs — the full deck
    case compact   // colour chips only — barely touches the screen

    var title: String {
        switch self {
        case .tabs: return String(localized: "Labelled tabs")
        case .compact: return String(localized: "Colour chips")
        }
    }
}

/// Resolved metrics for one fan.
///
/// Tabs *shingle*: each is full height but sits `pitch` below the one before, so
/// it laps over it like a roof tile. That keeps every tab tall enough to carry a
/// label while the deck as a whole stays well short of the screen.
struct DeckLayout {
    var itemHeight: CGFloat     // full height of one tab
    var pitch: CGFloat          // top-to-top spacing; < itemHeight means overlap
    var moreGap: CGFloat
    var moreHeight: CGFloat
    var count: Int
    var hasMore: Bool
    var panelHeight: CGFloat

    /// Negative for shingled tabs — VStack spacing that produces the overlap.
    var spacing: CGFloat { pitch - itemHeight }

    var stackHeight: CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count - 1) * pitch + itemHeight
            + (hasMore ? moreGap + moreHeight : 0)
            + DeckGeom.plusGap + DeckGeom.plusSize      // new note
            + DeckGeom.cogGap + DeckGeom.cogSize        // settings
    }

    var top: CGFloat { max(12, (panelHeight - stackHeight) / 2) }

    /// Centre of the strip of item `index` that is actually visible.
    func center(_ index: Int) -> CGFloat {
        let strip = index == count - 1 ? itemHeight : pitch
        return top + CGFloat(index) * pitch + strip / 2
    }

    var cap: CGFloat { max(140, panelHeight - 76) }
    var overflows: Bool { stackHeight > cap }
}

enum DeckGeom {
    /// Every length below is expressed at 100% and passed through `s(_:)`, so one
    /// preference resizes the deck as a whole. Rounding to whole points keeps the
    /// shingled tabs from landing on half pixels and showing a seam.
    static var scale: CGFloat { CGFloat(Settings.deckScale) }
    private static func s(_ v: CGFloat) -> CGFloat { (v * scale).rounded() }

    // Rest — a 12 pt pill of colour dashes
    static var pillWidth: CGFloat { s(12) }
    static var pillTouchWidth: CGFloat { s(14) }
    static var dashHeight: CGFloat { s(14) }
    static var dashWidth: CGFloat { s(7) }
    static var dashGap: CGFloat { s(5) }
    static var pillPad: CGFloat { s(7) }
    static let maxDashes = 14

    // Fan
    static var tabWidth: CGFloat { s(30) }
    static var tabGap: CGFloat { s(7) }
    /// How far the next tab laps over the one before it.
    static var tabLap: CGFloat { s(40) }
    static var pitchMin: CGFloat { s(56) }
    static var pitchMax: CGFloat { s(106) }
    /// The smallest pitch the guard rail may squeeze a tab down to.
    static var pitchFloor: CGFloat { s(36) }
    /// The strip is the label plus this much; the label is drawn inside it with
    /// `labelInset`. Keeping the two different is what leaves the last glyph room
    /// — sizing the strip to exactly the text width truncates on rounding.
    static var labelPad: CGFloat { s(20) }
    static var labelInset: CGFloat { s(12) }
    /// Tabs and notes are drawn a little past the screen edge so their lean cannot
    /// open a wedge of background between them and the edge they are stuck to.
    static var bleed: CGFloat { s(14) }

    /// Everything leans the same way — a deck of tabs at matching angles reads as
    /// deliberate, where per-note angles just look scattered.
    static let leanDegrees: Double = 3.0
    static func lean(onRight: Bool) -> Double { onRight ? -leanDegrees : leanDegrees }

    /// Rendered width of a tab label, used to size the strip that shows it.
    /// Must use the same face the tab draws with or the strip will not fit.
    ///
    /// Measured once per title per face: the deck asks for this on every layout
    /// pass, and text measurement is not cheap enough to repeat that often.
    private static var labelCache: [String: CGFloat] = [:]

    static func labelWidth(_ title: String) -> CGFloat {
        let text = title.uppercased() as NSString
        guard text.length > 0 else { return 0 }
        let font = Ink.tabNSFont
        let key = "\(font.fontName)|\(font.pointSize)|\(text)"
        if let hit = labelCache[key] { return hit }
        let w = text.size(withAttributes: [.font: font]).width
            + Ink.tabTracking * CGFloat(text.length)
        if labelCache.count > 400 { labelCache.removeAll(keepingCapacity: true) }
        labelCache[key] = w
        return w
    }
    static var chipWidth: CGFloat { s(30) }
    static var chipHeight: CGFloat { s(24) }
    static var chipGap: CGFloat { s(6) }
    static var fanWidth: CGFloat { s(50) }
    static var plusSize: CGFloat { s(28) }
    static var plusGap: CGFloat { s(12) }
    // The cog sits under the plus, so it has to grow with it.
    static var cogSize: CGFloat { s(24) }
    static var cogGap: CGFloat { s(8) }

    static var moreTabHeight: CGFloat { s(34) }

    /// The deck may claim at most this much of the screen before tabs start shrinking.
    static let heightBudget: CGFloat = 0.68

    /// The open note carries its own tab as a left gutter, so it reads as
    /// growing out of the deck rather than floating beside it. It matches the tab
    /// it grew from, so it scales with one.
    static var gutterWidth: CGFloat { tabWidth }

    // Expanded — the note slides clear of the deck
    static var editorWidth: CGFloat { Settings.noteSize.width }
    static var editorHeight: CGFloat { Settings.noteSize.height }
    /// The open note runs to the screen edge and covers its own tab, exactly as a
    /// pulled sticky would — so there is no gap between note and deck to tune.
    /// A little wider than the note so the lean has somewhere to go, and it grows
    /// with the note when the corner is dragged.
    static var expandedWidth: CGFloat { max(fanWidth, editorWidth) + 22 }


    static func pillHeight(noteCount: Int) -> CGFloat {
        let shown = min(noteCount, maxDashes)
        let n = max(1, shown + (noteCount > maxDashes ? 1 : 0))
        return pillPad * 2 + CGFloat(n) * dashHeight + CGFloat(n - 1) * dashGap
    }

    static func layout(panelHeight: CGFloat, count: Int, hasMore: Bool,
                       style: DeckStyle, longestLabel: CGFloat = 0) -> DeckLayout {
        let n = max(1, count)
        switch style {
        case .compact:
            return DeckLayout(itemHeight: chipHeight, pitch: chipHeight + chipGap,
                              moreGap: chipGap, moreHeight: 22,
                              count: n, hasMore: hasMore, panelHeight: panelHeight)
        case .tabs:
            // The uncovered strip of each tab is sized to the longest label on the
            // deck, so titles read in full until they hit the cap and ellipsise.
            var pitch = min(pitchMax, max(pitchMin, longestLabel + labelPad))

            // Guard rail: on a short display, shrink rather than run off-screen.
            let reserved = hasMore ? moreTabHeight + tabGap : 0
            let budget = panelHeight * heightBudget - reserved
            if CGFloat(n) * pitch + tabLap > budget {
                pitch = max(pitchFloor, (budget - tabLap) / CGFloat(n))
            }
            return DeckLayout(itemHeight: pitch + tabLap, pitch: pitch,
                              moreGap: tabGap, moreHeight: moreTabHeight,
                              count: n, hasMore: hasMore, panelHeight: panelHeight)
        }
    }
}

// MARK: - Panel

/// Borderless, non-activating floating panel. `canBecomeKey` must be overridden or
/// the expanded note silently refuses keystrokes.
final class DeckPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false                 // shadows are drawn per-tab in SwiftUI
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        applyLevel()
    }

    /// `.statusBar` is required to draw over full-screen apps; `.floating` alone is not.
    func applyLevel() {
        level = Settings.showOverFullScreen ? .statusBar : .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
}

// MARK: - Tracking container

/// Owns the tracking area that drives pill → fan. Hit-testing is delegated to the
/// SwiftUI hosting view so empty regions stay click-through to the app underneath.
final class DeckContentView: NSView {
    weak var controller: DeckController?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { controller?.pointerEntered() }
    override func mouseExited(with event: NSEvent) { controller?.pointerExited() }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option), controller?.canBeginPillDrag == true {
            controller?.beginPillDrag(with: event)
            return
        }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.showContextMenu(at: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit    // never swallow clicks on our own blank area
    }

    /// The deck is used while another app is frontmost, so a click must act on the
    /// first press rather than being eaten to activate the panel.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// SwiftUI host that also acts on the first click into an inactive panel, and lets
/// clicks on blank regions fall through to whatever is underneath.
final class DeckHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) { super.init(rootView: rootView) }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option),
           let content = superview as? DeckContentView,
           content.controller?.canBeginPillDrag == true {
            content.controller?.beginPillDrag(with: event)
            return
        }
        super.mouseDown(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
