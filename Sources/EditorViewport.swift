import AppKit

/// Keep the first visible text line in place while formatting changes glyphs,
/// wrapping and document height. A pixel offset alone drifts when text above
/// the viewport gets larger; source offsets also drift as style tags change.
struct EditorViewport {
    private let visibleOffset: Int
    private let lineFraction: CGFloat
    private let origin: NSPoint

    init?(_ textView: NSTextView) {
        guard !textView.hasMarkedText(), !textView.string.isEmpty,
              let scroll = textView.enclosingScrollView, scroll.documentView === textView,
              let layout = textView.layoutManager, let container = textView.textContainer else { return nil }
        layout.ensureLayout(for: container)
        guard layout.numberOfGlyphs > 0 else { return nil }
        origin = scroll.contentView.bounds.origin
        let inset = textView.textContainerOrigin
        let point = NSPoint(x: max(0, origin.x - inset.x), y: max(0, origin.y - inset.y))
        let glyph = min(layout.glyphIndex(for: point, in: container), layout.numberOfGlyphs - 1)
        var line = NSRange()
        let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line)
        let character = layout.characterIndexForGlyph(at: line.location)
        visibleOffset = NoteFormatting.visibleOffset(character, in: textView.string)
        lineFraction = (origin.y - inset.y - rect.minY) / max(1, rect.height)
    }

    func restore(in textView: NSTextView) {
        guard let scroll = textView.enclosingScrollView, scroll.documentView === textView,
              let layout = textView.layoutManager, let container = textView.textContainer else { return }
        // Finish layout before NSClipView constrains its scroll origin to the
        // document's new size. Otherwise it can clamp against a transient frame.
        layout.ensureLayout(for: container)
        textView.sizeToFit()
        var target = origin
        if origin.y > 0, layout.numberOfGlyphs > 0, !textView.string.isEmpty {
            let character = min(NoteFormatting.sourceOffset(visibleOffset, in: textView.string),
                                textView.string.utf16.count - 1)
            let glyph = layout.glyphIndexForCharacter(at: character)
            let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            target.y = rect.minY + textView.textContainerOrigin.y + lineFraction * rect.height
        }
        scroll.contentView.scroll(to: target)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
