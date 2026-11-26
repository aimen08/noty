import AppKit
import SwiftUI

// MARK: - Geometry

/// How the deck draws itself once it fans out.
enum DeckStyle: String, CaseIterable {
    case tabs      // labelled vertical tabs — the full deck
    case compact   // colour chips only — barely touches the screen

    var title: String {
        switch self {
        case .tabs: return L10n.text("deck_style.labelled_tabs")
        case .compact: return L10n.text("deck_style.colour_chips")
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
    var showsActions = true

    /// Negative for shingled tabs — VStack spacing that produces the overlap.
    var spacing: CGFloat { pitch - itemHeight }

    var stackHeight: CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count - 1) * pitch + itemHeight
            + (hasMore ? moreGap + moreHeight : 0)
            + (showsActions
               ? DeckGeom.plusGap + DeckGeom.plusSize   // new note
               + DeckGeom.cogGap + DeckGeom.cogSize     // settings
               : 0)
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

    /// Rendered width of a horizontal tab label, used for rotated runs.
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

    /// The vertical advance of one upright glyph in a tab label.
    static var tabGlyphAdvance: CGFloat {
        let font = Ink.tabNSFont
        return max(1, ceil(font.ascender - font.descender + font.leading))
    }

    /// Rendered height of a title when upright scripts use vertical writing.
    /// Latin runs still rotate as a run, so a mixed title retains readable words
    /// without forcing its CJK characters to lie on their sides.
    static func verticalLabelHeight(_ title: String) -> CGFloat {
        VerticalLabelLayout.runs(for: title.uppercased()).reduce(0) { $0 + $1.advance }
    }
    static var chipWidth: CGFloat { s(30) }
    static var chipHeight: CGFloat { s(24) }
    static var chipGap: CGFloat { s(6) }
    static var fanWidth: CGFloat { s(50) }
    static var plusSize: CGFloat { s(28) }
    static var plusGap: CGFloat { s(12) }
    // The cog sits under the plus, so it has to grow with it.
    static var cogSize: CGFloat { plusSize }
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
                       style: DeckStyle, longestLabel: CGFloat = 0,
                       showsActions: Bool = true) -> DeckLayout {
        let n = max(1, count)
        switch style {
        case .compact:
            return DeckLayout(itemHeight: chipHeight, pitch: chipHeight + chipGap,
                              moreGap: chipGap, moreHeight: 22,
                              count: n, hasMore: hasMore, panelHeight: panelHeight,
                              showsActions: showsActions)
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
                              count: n, hasMore: hasMore, panelHeight: panelHeight,
                              showsActions: showsActions)
        }
    }
}

// MARK: - Edge title column

/// One note the docked title column may list.
struct EdgeTitleNote: Equatable {
    var id: String
    var title: String
}

/// A strip in that column. `height` is the laid-out strip, after leftover
/// space has been shared out — or the natural strip when the column scrolls.
struct EdgeTitleSlot: Equatable {
    var id: String
    var highlighted: Bool
    var height: CGFloat
}

struct EdgeTitleLayout: Equatable {
    var slots: [EdgeTitleSlot]
    var scrolls: Bool
}

/// How the open note's edge column divides its height among titles.
///
/// Off, the column is the open note's own title at full height. On, every note
/// gets a strip: they share leftover space when they fit, and otherwise keep
/// their own strips so the column can scroll.
enum EdgeTitleColumn {
    /// The height one title wants before leftover space is shared out.
    /// Capped so one long title cannot force the whole column to scroll.
    static func stripHeight(for title: String) -> CGFloat {
        let label = DeckGeom.verticalLabelHeight(title)
        return min(DeckGeom.pitchMax, max(DeckGeom.pitchMin, label + DeckGeom.labelPad))
    }

    static func layout(notes: [EdgeTitleNote], currentID: String,
                       height: CGFloat, enabled: Bool) -> EdgeTitleLayout {
        let available = max(0, height)
        guard enabled else {
            return EdgeTitleLayout(
                slots: [EdgeTitleSlot(id: currentID, highlighted: true, height: available)],
                scrolls: false)
        }
        guard !notes.isEmpty else {
            return EdgeTitleLayout(slots: [], scrolls: false)
        }
        let natural = notes.map { stripHeight(for: $0.title) }
        let total = natural.reduce(0, +)
        if total > available {
            return EdgeTitleLayout(slots: zip(notes, natural).map { note, strip in
                EdgeTitleSlot(id: note.id, highlighted: note.id == currentID, height: strip)
            }, scrolls: true)
        }
        let extra = (available - total) / CGFloat(notes.count)
        var slots = zip(notes, natural).map { note, strip in
            EdgeTitleSlot(id: note.id, highlighted: note.id == currentID,
                          height: strip + extra)
        }
        let drift = available - slots.reduce(0) { $0 + $1.height }
        if let last = slots.indices.last {
            slots[last].height += drift
        }
        return EdgeTitleLayout(slots: slots, scrolls: false)
    }
}

// MARK: - Vertical tab labels

enum VerticalLabelOrientation: Equatable {
    case upright
    case rotated
}

struct VerticalLabelRun: Equatable {
    let text: String
    let orientation: VerticalLabelOrientation

    var advance: CGFloat {
        switch orientation {
        case .upright:
            DeckGeom.tabGlyphAdvance
        case .rotated:
            DeckGeom.labelWidth(text)
        }
    }
}

/// A small Unicode-aware layout model shared by the deck's measurement and
/// rendering. CJK, kana, hangul, full-width punctuation and emoji have an
/// upright presentation in vertical writing; scripts whose glyphs are normally
/// rotated stay grouped so words and numbers remain legible.
enum VerticalLabelLayout {
    static func runs(for title: String) -> [VerticalLabelRun] {
        var result: [VerticalLabelRun] = []
        var rotated = ""

        func flushRotated() {
            guard !rotated.isEmpty else { return }
            result.append(VerticalLabelRun(text: rotated, orientation: .rotated))
            rotated.removeAll(keepingCapacity: true)
        }

        let characters = Array(title)
        for (index, character) in characters.enumerated() {
            let upright = isUpright(character)
                && (!isSpace(character) || spaceIsBetweenUprightGlyphs(
                    in: characters, at: index))
            if upright {
                flushRotated()
                // Keep each ideograph in its own line box. Grouping them into a
                // single Text would make SwiftUI lay them out horizontally.
                result.append(VerticalLabelRun(text: String(character), orientation: .upright))
            } else {
                rotated.append(character)
            }
        }
        flushRotated()
        return result
    }

    private static func spaceIsBetweenUprightGlyphs(in characters: [Character],
                                                    at index: Int) -> Bool {
        let previous = index > 0 ? characters[index - 1] : nil
        let next = index + 1 < characters.count ? characters[index + 1] : nil
        let previousIsUpright = previous.map(isUpright) ?? true
        let nextIsUpright = next.map(isUpright) ?? true
        return previousIsUpright && nextIsUpright
    }

    private static func isSpace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            scalar.value == 0x20 || scalar.value == 0x3000 || scalar.value == 0x00A0
        }
    }

    /// Truncate the logical title from its end, adding an upright ellipsis when
    /// the display strip is squeezed by a short screen or a long title.
    static func fittingRuns(for title: String, maxAdvance: CGFloat) -> [VerticalLabelRun] {
        let text = title.uppercased()
        let all = runs(for: text)
        let total = all.reduce(0) { $0 + $1.advance }
        guard total > maxAdvance else { return all }

        let ellipsis = VerticalLabelRun(text: "…", orientation: .upright)
        var prefix = ""
        for character in text {
            let candidate = prefix + String(character)
            let candidateHeight = runs(for: candidate).reduce(0) { $0 + $1.advance }
            guard candidateHeight + ellipsis.advance <= maxAdvance else { break }
            prefix = candidate
        }

        return runs(for: prefix) + [ellipsis]
    }

    static func isUpright(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            let value = scalar.value
            switch value {
            case 0x2E80...0x2FFF, // CJK radicals, symbols and punctuation
                 0x3000...0x30FF, // CJK punctuation, hiragana and katakana
                 0x3100...0x31FF, // bopomofo and kana extensions
                 0x3400...0x4DBF, // CJK extension A
                 0x4E00...0x9FFF, // CJK unified ideographs
                 0xA960...0xA97F, // hangul jamo extended A
                 0xAC00...0xD7FF, // hangul syllables and extended B
                 0xF900...0xFAFF, // CJK compatibility ideographs
                 0xFE10...0xFE6F, // vertical/CJK compatibility forms
                 0xFF00...0xFFEF, // full-width forms
                 0x1F000...0x1FAFF, // emoji and pictographs
                 0x20000...0x2FA1F: // CJK extensions B through I
                return true
            case 0x20, 0x3000, 0x00A0:
                // A space is a vertical blank between upright glyphs. Keeping
                // it eligible for upright layout lets CJK-only titles keep their
                // spacing, while runs(for:) attaches mixed-script spaces to the
                // neighbouring rotated text.
                return true
            default:
                return false
            }
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
        // .fullScreenAuxiliary is what lets the panel join a full-screen space
        // at all — granting it unconditionally showed the deck over full-screen
        // apps with the setting off, just at a lower level (issue #27).
        var behavior: NSWindow.CollectionBehavior = [.stationary, .ignoresCycle]
        if !Settings.confineToSpace { behavior.insert(.canJoinAllSpaces) }
        if Settings.showOverFullScreen { behavior.insert(.fullScreenAuxiliary) }
        collectionBehavior = behavior
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
