import Foundation

/// The on-disk form of a note in the sync folder: a Markdown document with a
/// front-matter header. Pure string work — no file system, no AppKit — so the
/// format is fully covered by tests.
///
/// Identity lives in the header, never in the filename, so renaming a note (or
/// renaming its file from a phone) never creates a duplicate.
enum NoteDocument {
    /// The delimiter line, opening and closing.
    static let fence = "---"

    /// Stable header key names. These are a file format, not user-facing copy —
    /// they never pass through L10n and must never be renamed.
    enum Key {
        static let id = "noty-id"
        static let color = "color"
        static let created = "created"
        static let modified = "modified"
        static let archived = "archived"
        static let pinned = "pinned"
        static let order = "order"
        static let direction = "direction"
        static let title = "title"

        static let all: Set<String> = [id, color, created, modified,
                                       archived, pinned, order, direction, title]
    }

    static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func render(_ note: Note) -> String {
        var header = [
            "\(Key.id): \(note.id)",
            "\(Key.color): \(note.color)",
            "\(Key.created): \(stamp.string(from: note.created))",
            "\(Key.modified): \(stamp.string(from: note.modified))",
            "\(Key.archived): \(note.archived)",
            "\(Key.pinned): \(note.pinned)",
            "\(Key.order): \(note.order)",
            "\(Key.direction): \(note.textDirection.rawValue)",
        ]
        // An empty title means "derive it from the first line" — a rule the model
        // owns. Writing the derived value out would freeze it, exactly the bug
        // NoteStore.migrateDerivedTitles exists to undo.
        if note.hasCustomTitle {
            header.append("\(Key.title): \(singleLine(note.title))")
        }
        return fence + "\n"
            + header.joined(separator: "\n") + "\n"
            + fence + "\n\n"
            + Tasks.toMarkdown(note.body)
    }

    /// A title is one line by construction, but a header cannot survive a stray
    /// newline, so fold rather than trust.
    private static func singleLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    struct Parsed {
        var note: Note
        /// False when the file carried no `noty-id` — something a person created
        /// on a phone that Noty has never seen. The caller gives it an id and
        /// writes the file back with one.
        var hasIdentity: Bool
    }

    /// `fallbackTitle` is used only when the file can supply no title at all —
    /// no header title and no derivable first line. Callers pass the filename.
    static func parse(_ text: String, fallbackTitle: String) -> Parsed {
        var note = Note()
        var hasIdentity = false
        var body = text

        if let (fields, rest) = splitHeader(text) {
            body = rest
            for (key, value) in fields {
                switch key {
                case Key.id where !value.isEmpty:
                    note.id = value
                    hasIdentity = true
                case Key.color:     note.color = Int(value) ?? note.color
                case Key.created:   note.created = stamp.date(from: value) ?? note.created
                case Key.modified:  note.modified = stamp.date(from: value) ?? note.modified
                case Key.archived:  note.archived = (value == "true")
                case Key.pinned:    note.pinned = (value == "true")
                case Key.order:     note.order = Double(value) ?? note.order
                case Key.direction: note.textDirection = NoteTextDirection(rawValue: value) ?? .automatic
                case Key.title:     note.title = value
                default: break
                }
            }
        }

        note.body = Tasks.fromMarkdown(body)
        if !note.hasCustomTitle && Note.derivedTitle(from: note.body).isEmpty {
            note.title = fallbackTitle
        }
        return Parsed(note: note, hasIdentity: hasIdentity)
    }

    /// Header fields and the remaining body, or nil when there is no header.
    ///
    /// Strict on purpose. Accepting any leading `---` meant a note that opened
    /// with a horizontal rule lost everything up to the next rule — and because
    /// such a file has no identity, `adopt` wrote the truncation straight back.
    /// A header must be entirely `key: value` lines and must carry at least one
    /// key Noty itself writes.
    private static func splitHeader(_ text: String) -> ([(String, String)], String)? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == fence else { return nil }
        // ArraySlice keeps the base indices, so this indexes back into `lines`.
        guard let close = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == fence
        }) else { return nil }

        var fields: [(String, String)] = []
        for line in lines[1..<close] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { return nil }
            let key = String(trimmed[trimmed.startIndex..<colon])
            guard isHeaderKey(key) else { return nil }
            let value = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            fields.append((key, value))
        }
        guard fields.contains(where: { Key.all.contains($0.0) }) else { return nil }

        var rest = Array(lines[(close + 1)...])
        if rest.first?.isEmpty == true { rest.removeFirst() }   // the blank line render writes
        return (fields, rest.joined(separator: "\n"))
    }

    private static func isHeaderKey(_ key: String) -> Bool {
        guard let first = key.first, first.isLetter else { return false }
        return key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}
