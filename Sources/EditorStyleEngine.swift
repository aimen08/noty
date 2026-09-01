import AppKit

extension NSAttributedString.Key {
    /// Marks Markdown punctuation that should occupy no glyph space while the
    /// plain-text source remains untouched.
    static let notyHidden = NSAttributedString.Key("notyHidden")
}

/// Accumulates TextKit character edits until it is safe to style them.
/// Marked-text composition deliberately leaves the pending ranges untouched.
struct EditorEditAccumulator {
    private(set) var pending: [NSRange] = []

    var hasPendingEdits: Bool { !pending.isEmpty }

    mutating func record(_ range: NSRange) {
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0 else { return }
        pending.append(range)
    }

    mutating func consume(in text: NSString, hasMarkedText: Bool) -> [NSRange] {
        guard !hasMarkedText, !pending.isEmpty else { return [] }
        let edits = pending
        pending.removeAll(keepingCapacity: true)
        return EditorStyleEngine.affectedLineRanges(for: edits, in: text)
    }

    mutating func clear() {
        pending.removeAll(keepingCapacity: true)
    }
}

/// Applies note attributes without owning editor state. Every normal edit is
/// planned as one or more complete-line ranges; full-document work is reserved
/// for initial content and explicit configuration changes.
enum EditorStyleEngine {
    typealias FontProvider = (CGFloat) -> NSFont
    typealias CompletedTaskPredicate = (String) -> Bool

    private static let heading = try! NSRegularExpression(
        pattern: "^(#{1,6})[ \\t]+(.+)$", options: [.anchorsMatchLines])
    private static let bold = try! NSRegularExpression(
        pattern: "(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    private static let italic = try! NSRegularExpression(
        pattern: "(?<![\\*_])([\\*_])(?=[^\\*_\\s])(.+?)(?<=[^\\*_\\s])\\1(?![\\*_])")
    private static let code = try! NSRegularExpression(pattern: "`([^`\\n]+)`")
    private static let struck = try! NSRegularExpression(
        pattern: "~~(?=\\S)(.+?)(?<=\\S)~~")
    private static let quote = try! NSRegularExpression(
        pattern: "^>[ \\t]?(.*)$", options: [.anchorsMatchLines])
    private static let bullet = try! NSRegularExpression(
        pattern: "^[ \\t]*([-*+])[ \\t]+", options: [.anchorsMatchLines])
    private static let link = try! NSRegularExpression(
        pattern: "\\[([^\\]\\n]+)\\]\\(([^)\\s]+)\\)")

    /// A note is ordinary text, and text can carry any scheme somebody typed or
    /// imported. Only these three are ever made clickable — the rest are styled
    /// and inert, so a note can never become a launcher for something else.
    private static let openableSchemes: Set<String> = ["http", "https", "mailto"]

    /// The destination of a Markdown link, or nil if it is not one of ours.
    static func openableURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              openableSchemes.contains(scheme) else { return nil }
        return url
    }

    /// The complete line containing a UTF-16 location. At EOF after a trailing
    /// newline this correctly returns the zero-length final line.
    static func lineRange(containing location: Int, in text: NSString) -> NSRange {
        let safeLocation = min(max(0, location), text.length)
        return text.lineRange(for: NSRange(location: safeLocation, length: 0))
    }

    /// Expand character edits to complete lines. One character on either side
    /// is included before expansion so inserting/deleting a newline restyles
    /// both paragraphs that changed identity.
    static func affectedLineRanges(for edits: [NSRange], in text: NSString) -> [NSRange] {
        guard !edits.isEmpty else { return [] }
        guard text.length > 0 else { return [NSRange(location: 0, length: 0)] }

        let expanded = edits.compactMap { edit -> NSRange? in
            guard let safe = clamped(edit, to: text.length) else { return nil }
            let lower = max(0, safe.location - 1)
            let upper = min(text.length, safe.location + safe.length + 1)
            return text.lineRange(for: NSRange(location: lower, length: upper - lower))
        }
        return merged(expanded, length: text.length, keepingEmpty: false)
    }

    /// Clamp, sort, and merge only overlapping or adjacent ranges. Distant
    /// caret lines stay disjoint so styling never scans the gap between them.
    static func normalizedStyleRanges(_ ranges: [NSRange], length: Int) -> [NSRange] {
        merged(ranges, length: length, keepingEmpty: false)
    }

    /// Apply base, Markdown, and completed-task attributes to scoped ranges.
    /// The string and selection are never mutated.
    @discardableResult
    static func apply(to textView: NSTextView,
                      ranges: [NSRange],
                      revealing activeLine: NSRange?,
                      ink: NSColor,
                      size: CGFloat,
                      markdownEnabled: Bool,
                      textDirection: NoteTextDirection = .automatic,
                      bodyFont: @escaping FontProvider,
                      isCompletedTask: @escaping CompletedTaskPredicate) -> [NSRange] {
        let font = bodyFont(size)
        let paragraphStyle = textDirection.paragraphStyle
        textView.typingAttributes = [.font: font, .foregroundColor: ink,
                                     .paragraphStyle: paragraphStyle]

        guard let storage = textView.textStorage else { return [] }
        let planned = normalizedStyleRanges(ranges, length: storage.length)
        guard !planned.isEmpty else { return [] }

        for range in planned {
            // Process disjoint ranges separately. NSTextStorage coalesces edits
            // inside one begin/end pair, which would otherwise invalidate the
            // untouched gap between two distant caret lines.
            storage.beginEditing()
            storage.removeAttribute(.strikethroughStyle, range: range)
            storage.removeAttribute(.obliqueness, range: range)
            storage.removeAttribute(.backgroundColor, range: range)
            storage.removeAttribute(.notyHidden, range: range)
            // Both belong to links. Styling is line-scoped, so an attribute left
            // behind when the syntax around it is deleted never gets cleaned up
            // by a later pass — the line would stay underlined and clickable.
            storage.removeAttribute(.underlineStyle, range: range)
            storage.removeAttribute(.link, range: range)
            storage.addAttribute(.foregroundColor, value: ink, range: range)
            storage.addAttribute(.font, value: font, range: range)
            applyParagraphStyles(to: storage, range: range, direction: textDirection)

            let fragment = storage.mutableString.substring(with: range)
            if markdownEnabled {
                markdown(storage, fragment, offset: range.location, ink: ink,
                         size: size, revealing: activeLine, bodyFont: bodyFont)
            }
            styleCompletedTasks(storage, fragment, offset: range.location,
                                ink: ink, isCompletedTask: isCompletedTask)
            storage.endEditing()

            // Hidden markers require glyph regeneration, but only for the lines
            // whose attributes were actually touched.
            textView.layoutManager?.invalidateGlyphs(forCharacterRange: range,
                                                      changeInLength: 0,
                                                      actualCharacterRange: nil)
            textView.layoutManager?.invalidateLayout(forCharacterRange: range,
                                                      actualCharacterRange: nil)
            textView.layoutManager?.invalidateDisplay(forCharacterRange: range)
        }
        return planned
    }

    /// Apply Automatic independently to every paragraph so mixed-language
    /// notes can contain both English and Arabic/Hebrew paragraphs naturally.
    private static func applyParagraphStyles(to storage: NSTextStorage,
                                             range: NSRange,
                                             direction: NoteTextDirection) {
        guard direction == .automatic else {
            storage.addAttribute(.paragraphStyle, value: direction.paragraphStyle, range: range)
            return
        }

        let text = storage.mutableString
        let upperBound = NSMaxRange(range)
        var location = range.location
        while location < upperBound {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            let target = NSIntersectionRange(paragraph, range)
            guard target.length > 0 else { break }
            let contents = text.substring(with: paragraph)
            storage.addAttribute(.paragraphStyle,
                                 value: direction.paragraphStyle(for: contents),
                                 range: target)
            location = NSMaxRange(target)
        }
    }

    /// The only characters any of the expressions below can match on. A link
    /// needs its opening bracket, and nothing else in a URL is Markdown at all —
    /// leaving `[` out here silently switched links off.
    private static let markdownChars = CharacterSet(charactersIn: "*_`~#>-+[")

    private static func markdown(_ storage: NSTextStorage, _ fragment: String,
                                 offset: Int, ink: NSColor, size: CGFloat,
                                 revealing activeLine: NSRange?,
                                 bodyFont: @escaping FontProvider) {
        let local = fragment as NSString
        let full = NSRange(location: 0, length: local.length)
        // Seven regex passes over the fragment. Most lines carry no Markdown at
        // all, and one scan for the punctuation that could possibly match is far
        // cheaper than finding that out seven times.
        guard local.rangeOfCharacter(from: markdownChars).location != NSNotFound else { return }
        let faint = ink.withAlphaComponent(0.32)

        func global(_ range: NSRange) -> NSRange {
            NSRange(location: offset + range.location, length: range.length)
        }

        /// Punctuation is hidden unless it intersects the active caret line.
        func dim(_ localRange: NSRange) {
            let range = global(localRange)
            if let activeLine,
               NSIntersectionRange(range, activeLine).length > 0 || activeLine.location == range.location {
                storage.addAttribute(.foregroundColor, value: faint, range: range)
            } else {
                storage.addAttribute(.notyHidden, value: true, range: range)
                storage.addAttribute(.foregroundColor, value: faint, range: range)
            }
        }

        func each(_ expression: NSRegularExpression,
                  _ body: @escaping (NSTextCheckingResult) -> Void) {
            expression.enumerateMatches(in: fragment, range: full) { match, _, _ in
                if let match { body(match) }
            }
        }

        each(heading) { match in
            let level = match.range(at: 1).length
            let bump = max(1.5, 7 - CGFloat(level) * 1.1)
            storage.addAttribute(.font, value: heavier(size + bump, bodyFont: bodyFont),
                                 range: global(match.range))
            dim(match.range(at: 1))
        }
        // [label](url) — the label is what stays; the brackets and the URL go the
        // way of every other marker.
        each(link) { match in
            let label = match.range(at: 1)
            storage.addAttribute(.underlineStyle,
                                 value: NSUnderlineStyle.single.rawValue, range: global(label))
            if let url = openableURL(local.substring(with: match.range(at: 2))) {
                storage.addAttribute(.link, value: url, range: global(label))
            }
            dim(NSRange(location: match.range.location, length: 1))
            dim(NSRange(location: label.upperBound,
                        length: match.range.upperBound - label.upperBound))
        }
        each(bold) { match in
            storage.addAttribute(.font, value: heavier(size, bodyFont: bodyFont),
                                 range: global(match.range(at: 2)))
            dim(NSRange(location: match.range.location, length: 2))
            dim(NSRange(location: match.range.upperBound - 2, length: 2))
        }
        each(italic) { match in
            storage.addAttribute(.obliqueness, value: 0.2,
                                 range: global(match.range(at: 2)))
            dim(NSRange(location: match.range.location, length: 1))
            dim(NSRange(location: match.range.upperBound - 1, length: 1))
        }
        each(code) { match in
            storage.addAttribute(.font,
                                 value: NSFont.monospacedSystemFont(ofSize: size - 0.5,
                                                                    weight: .regular),
                                 range: global(match.range(at: 1)))
            storage.addAttribute(.backgroundColor, value: ink.withAlphaComponent(0.07),
                                 range: global(match.range(at: 1)))
            dim(NSRange(location: match.range.location, length: 1))
            dim(NSRange(location: match.range.upperBound - 1, length: 1))
        }
        each(struck) { match in
            storage.addAttribute(.strikethroughStyle,
                                 value: NSUnderlineStyle.single.rawValue,
                                 range: global(match.range(at: 1)))
            dim(NSRange(location: match.range.location, length: 2))
            dim(NSRange(location: match.range.upperBound - 2, length: 2))
        }
        each(quote) { match in
            storage.addAttribute(.foregroundColor, value: ink.withAlphaComponent(0.62),
                                 range: global(match.range))
            storage.addAttribute(.obliqueness, value: 0.15,
                                 range: global(match.range(at: 1)))
            dim(NSRange(location: match.range.location, length: 1))
        }
        each(bullet) { match in
            storage.addAttribute(.foregroundColor, value: ink.withAlphaComponent(0.5),
                                 range: global(match.range(at: 1)))
        }
    }

    private static func styleCompletedTasks(_ storage: NSTextStorage, _ fragment: String,
                                            offset: Int, ink: NSColor,
                                            isCompletedTask: @escaping CompletedTaskPredicate) {
        let local = fragment as NSString
        let full = NSRange(location: 0, length: local.length)
        local.enumerateSubstrings(in: full, options: .byLines) { line, range, _, _ in
            guard let line, isCompletedTask(line) else { return }
            let global = NSRange(location: offset + range.location, length: range.length)
            storage.addAttribute(.strikethroughStyle,
                                 value: NSUnderlineStyle.single.rawValue, range: global)
            storage.addAttribute(.foregroundColor,
                                 value: ink.withAlphaComponent(0.45), range: global)
        }
    }

    private static func heavier(_ size: CGFloat, bodyFont: FontProvider) -> NSFont {
        let base = bodyFont(size)
        let boldFont = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        return boldFont != base ? boldFont : NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    private static func clamped(_ range: NSRange, to length: Int) -> NSRange? {
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0 else { return nil }
        let location = min(range.location, length)
        let available = length - location
        return NSRange(location: location, length: min(range.length, available))
    }

    private static func merged(_ ranges: [NSRange], length: Int,
                               keepingEmpty: Bool) -> [NSRange] {
        let safe = ranges.compactMap { clamped($0, to: length) }
            .filter { keepingEmpty || $0.length > 0 }
            .sorted {
                $0.location == $1.location ? $0.length < $1.length : $0.location < $1.location
            }
        guard var current = safe.first else { return [] }

        var result: [NSRange] = []
        for next in safe.dropFirst() {
            if next.location <= current.location + current.length {
                let upper = max(current.location + current.length,
                                next.location + next.length)
                current.length = upper - current.location
            } else {
                result.append(current)
                current = next
            }
        }
        result.append(current)
        return result
    }
}
