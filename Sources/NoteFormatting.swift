import AppKit
import SwiftUI

extension NSAttributedString.Key {
    static let notyTextStyle = NSAttributedString.Key("notyTextStyle")
    static let notyFormattingMarker = NSAttributedString.Key("notyFormattingMarker")
}

struct NoteTextStyle: Equatable {
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    var size: Int?

    var code: String {
        ([bold ? "b" : nil, italic ? "i" : nil, underline ? "u" : nil,
          strike ? "s" : nil, size.map { "z\($0)" }].compactMap { $0 }).joined(separator: ",")
    }

    init(code: String = "") {
        let parts = code.split(separator: ",").map(String.init)
        bold = parts.contains("b"); italic = parts.contains("i")
        underline = parts.contains("u"); strike = parts.contains("s")
        size = parts.first(where: { $0.hasPrefix("z") }).flatMap { Int($0.dropFirst()) }
        if let value = size, !(8...72).contains(value) { size = nil }
    }

    var css: String {
        var values: [String] = []
        if bold { values.append("font-weight:700") }
        if italic { values.append("font-style:italic") }
        let decorations = [underline ? "underline" : nil, strike ? "line-through" : nil].compactMap { $0 }
        if !decorations.isEmpty { values.append("text-decoration:" + decorations.joined(separator: " ")) }
        if let size { values.append("font-size:\(size)px") }
        return values.joined(separator: ";")
    }
}

/// Explicit formatting travels with the existing text payload, so database,
/// sync and .stickies backups preserve it without a second source of truth.
/// Commands decode into logical text before editing: partial selections never
/// nest wrappers or accidentally toggle the surrounding text as well.
enum NoteFormatting {
    enum Command { case bold, italic, underline, strike, size(Int?), clear }
    struct Run {
        let range: NSRange
        let content: NSRange
        let style: NoteTextStyle
        var markers: [NSRange] {
            [NSRange(location: range.location, length: content.location - range.location),
             NSRange(location: NSMaxRange(content), length: NSMaxRange(range) - NSMaxRange(content))]
        }
    }
    struct Edit { let text: String; let selection: NSRange }
    static let marker = "<span data-noty-style=\""
    private static let expression = try! NSRegularExpression(
        pattern: #"<span data-noty-style="([biusz0-9,]+)">([\s\S]*?)</span>"#)
    private static let leaders = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:[☐☑][ \t]*|[-*+] \[[ xX]\][ \t]*|#{1,6}[ \t]+|[>+*-][ \t]+|\d+[.)][ \t]+)"#,
        options: [.anchorsMatchLines])
    private static let breaks = try! NSRegularExpression(pattern: "[\\r\\n]+")

    private static func protectedRanges(in text: String) -> [NSRange] {
        let full = NSRange(location: 0, length: text.utf16.count)
        return leaders.matches(in: text, range: full).map(\.range)
            + breaks.matches(in: text, range: full).map(\.range)
            + ImageStore.tokens(in: text).map(\.range)
    }

    static func runs(in text: String) -> [Run] {
        guard text.contains(marker) else { return [] }
        let ns = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            let code = ns.substring(with: $0.range(at: 1))
            let style = NoteTextStyle(code: code)
            guard style.code == code else { return nil }
            return Run(range: $0.range, content: $0.range(at: 2), style: style)
        }
    }

    static func plainText(_ text: String) -> String {
        let result = NSMutableString(string: text)
        for run in runs(in: text).reversed() {
            for range in run.markers.reversed() { result.deleteCharacters(in: range) }
        }
        return result as String
    }

    /// UTF-16 positions in the visible text survive adding/removing style tags.
    static func visibleOffset(_ sourceOffset: Int, in text: String) -> Int {
        let offset = min(max(0, sourceOffset), text.utf16.count)
        return offset - runs(in: text).flatMap(\.markers).reduce(0) {
            $0 + max(0, min($1.length, offset - $1.location))
        }
    }

    static func sourceOffset(_ visibleOffset: Int, in text: String) -> Int {
        var offset = max(0, visibleOffset)
        for marker in runs(in: text).flatMap(\.markers) {
            guard marker.location <= offset else { break }
            offset += marker.length
        }
        return min(offset, text.utf16.count)
    }

    static func markdown(_ text: String) -> String {
        let result = NSMutableString(string: text)
        for run in runs(in: text).reversed() {
            result.replaceCharacters(in: run.markers[0], with: "<span style=\"\(run.style.css)\">")
        }
        return result as String
    }

    static func edit(_ source: String, selection: NSRange, command: Command) -> Edit? {
        let ns = source as NSString
        guard selection.location != NSNotFound, selection.location >= 0,
              selection.length >= 0, NSMaxRange(selection) <= ns.length else { return nil }
        let document = Document(source)
        let text = document.text
        let original = document.logical(selection)
        var target = original
        if target.length == 0 {
            var start = 0, end = 0, contentsEnd = 0
            (text.string as NSString).getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                                                  for: target)
            target = NSRange(location: start, length: contentsEnd - start)
        }
        guard target.length > 0 else { return nil }
        var editableRanges = [target]
        for excluded in protectedRanges(in: text.string) {
            editableRanges = editableRanges.flatMap { range -> [NSRange] in
                let overlap = NSIntersectionRange(range, excluded)
                guard overlap.length > 0 else { return [range] }
                return [NSRange(location: range.location, length: overlap.location - range.location),
                        NSRange(location: NSMaxRange(overlap), length: NSMaxRange(range) - NSMaxRange(overlap))]
                    .filter { $0.length > 0 }
            }
        }
        var segments: [(NSRange, NoteTextStyle)] = []
        for range in editableRanges {
            text.enumerateAttribute(.notyTextStyle, in: range) { value, range, _ in
                segments.append((range, NoteTextStyle(code: value as? String ?? "")))
            }
        }
        guard !segments.isEmpty else { return nil }
        func enabled(_ style: NoteTextStyle) -> Bool {
            switch command {
            case .bold: style.bold
            case .italic: style.italic
            case .underline: style.underline
            case .strike: style.strike
            default: false
            }
        }
        let turnOn = !segments.allSatisfy { enabled($0.1) }
        for (range, old) in segments {
            var style = old
            switch command {
            case .bold: style.bold = turnOn
            case .italic: style.italic = turnOn
            case .underline: style.underline = turnOn
            case .strike: style.strike = turnOn
            case .size(let size): style.size = size.map { min(72, max(8, $0)) }
            case .clear: style = NoteTextStyle()
            }
            text.addAttribute(.notyTextStyle, value: style.code, range: range)
        }

        let result = serialize(text, selection: original)
        return result.text == source ? nil : result
    }

    private struct Document {
        let text: NSMutableAttributedString
        let markers: [NSRange]
        init(_ source: String) {
            let runs = NoteFormatting.runs(in: source)
            markers = runs.flatMap(\.markers)
            text = NSMutableAttributedString(string: NoteFormatting.plainText(source))
            for run in runs {
                text.addAttribute(.notyTextStyle, value: run.style.code, range: logical(run.content))
            }
        }
        func logical(_ offset: Int) -> Int {
            offset - markers.reduce(0) { $0 + max(0, min($1.length, offset - $1.location)) }
        }
        func logical(_ range: NSRange) -> NSRange {
            NSRange(location: logical(range.location), length: logical(NSMaxRange(range)) - logical(range.location))
        }
    }

    /// Edit logical text when a replacement crosses a style marker or splits
    /// a styled paragraph. Newlines belong outside the hidden wrappers so an
    /// empty next line does not consist solely of an invisible closing tag.
    static func replacing(_ source: String, range: NSRange, with replacement: String) -> Edit? {
        guard range.location != NSNotFound, range.location >= 0,
              NSMaxRange(range) <= source.utf16.count else { return nil }
        let document = Document(source)
        let crossesMarker = document.markers.contains { NSIntersectionRange($0, range).length > 0 }
        let splitsStyle = replacement.contains(where: \.isNewline) && runs(in: source).contains {
            range.location >= $0.content.location && range.location <= NSMaxRange($0.content)
        }
        guard crossesMarker || splitsStyle else { return nil }
        let target = document.logical(range)
        let inherited: [NSAttributedString.Key: Any]
        if target.location < document.text.length {
            inherited = document.text.attributes(at: target.location, effectiveRange: nil)
        } else { inherited = [:] }
        document.text.replaceCharacters(in: target, with: NSAttributedString(string: replacement, attributes: inherited))
        return serialize(document.text, selection: NSRange(location: target.location + replacement.utf16.count, length: 0))
    }

    static func selectedText(_ source: String, range: NSRange) -> String {
        let document = Document(source)
        return (document.text.string as NSString).substring(with: document.logical(range))
    }

    private static func serialize(_ text: NSMutableAttributedString, selection original: NSRange) -> Edit {

        // Keep paragraph syntax and image tokens outside spans, so tasks,
        // headings and images keep their existing editing behavior.
        let full = NSRange(location: 0, length: text.length)
        for range in protectedRanges(in: text.string) {
            text.removeAttribute(.notyTextStyle, range: range)
        }

        var output = ""
        var starts = [Int](repeating: 0, count: text.length + 1)
        var ends = starts
        text.enumerateAttribute(.notyTextStyle, in: full) { value, range, _ in
            let code = value as? String ?? ""
            let fragment = (text.string as NSString).substring(with: range)
            if !code.isEmpty { output += marker + code + "\">" }
            let start = output.utf16.count
            for i in 0..<range.length {
                starts[range.location + i] = start + i
                ends[range.location + i + 1] = start + i + 1
            }
            output += fragment
            if !code.isEmpty { output += "</span>" }
        }
        starts[text.length] = output.utf16.count
        let restored: NSRange
        if original.length == 0 {
            restored = NSRange(location: original.location == 0 ? starts[0] : ends[original.location], length: 0)
        } else {
            restored = NSRange(location: starts[original.location],
                               length: ends[NSMaxRange(original)] - starts[original.location])
        }
        return Edit(text: output, selection: restored)
    }

    static func apply(_ runs: [Run], to storage: NSTextStorage, in range: NSRange,
                      bodyFont: (CGFloat) -> NSFont) {
        for run in runs where NSIntersectionRange(run.range, range).length > 0 {
            let content = NSIntersectionRange(run.content, range)
            let style = run.style
            if content.length > 0 {
                var fonts: [(NSRange, NSFont)] = []
                storage.enumerateAttribute(.font, in: content) { value, span, _ in
                    var font = value as? NSFont ?? bodyFont(13.5)
                    if let size = style.size { font = NSFontManager.shared.convert(font, toSize: CGFloat(size)) }
                    if style.bold {
                        let converted = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                        font = converted != font ? converted : NSFont.systemFont(ofSize: font.pointSize, weight: .bold)
                    }
                    fonts.append((span, font))
                }
                for (span, font) in fonts { storage.addAttribute(.font, value: font, range: span) }
                if style.italic { storage.addAttribute(.obliqueness, value: 0.2, range: content) }
                if style.underline { storage.addAttribute(.underlineStyle, value: 1, range: content) }
                if style.strike { storage.addAttribute(.strikethroughStyle, value: 1, range: content) }
            }
            for marker in run.markers {
                let target = NSIntersectionRange(marker, range)
                if target.length > 0 {
                    storage.addAttributes([.notyHidden: true, .notyFormattingMarker: true], range: target)
                }
            }
        }
    }
}

extension EditorBridge {
    func format(_ command: NoteFormatting.Command) {
        guard let tv = textView as? TaskTextView else { return }
        tv.applyFormatting(command)
    }
}

struct NoteFormattingBar: View {
    let bridge: EditorBridge
    var foreground: Color = .primary

    var body: some View {
        HStack(spacing: 4) {
            button("format.bold", "bold", .bold)
            button("format.italic", "italic", .italic)
            button("format.underline", "underline", .underline)
            button("format.strike", "strikethrough", .strike)
            Menu {
                Button(L10n.text("format.default_size")) { bridge.format(.size(nil)) }
                ForEach([10, 12, 14, 16, 18, 20, 24, 28, 32], id: \.self) { size in
                    Button("\(size) pt") { bridge.format(.size(size)) }
                }
            } label: { Image(systemName: "textformat.size").frame(width: 28, height: 22) }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel(L10n.text("format.size"))
                .help(L10n.text("format.size"))
            button("format.clear", "textformat", .clear)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12)).foregroundStyle(foreground)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .help(L10n.text("format.scope"))
    }

    private func button(_ title: String, _ symbol: String, _ command: NoteFormatting.Command) -> some View {
        Button { bridge.format(command) } label: {
            Image(systemName: symbol).frame(width: 25, height: 22).contentShape(Rectangle())
        }.buttonStyle(.plain).help(L10n.text(title)).accessibilityLabel(L10n.text(title))
    }
}
