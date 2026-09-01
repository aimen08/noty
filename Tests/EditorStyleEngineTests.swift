import AppKit
import Darwin
import SQLite3
import SwiftUI

@main
struct EditorStyleEngineTests {
    private static var failures = 0

    static func main() {
        testSingleCharacterScope()
        testNewlineBoundaries()
        testDistantRangesStayDisjoint()
        testUTF16Ranges()
        testMarkedTextAccumulation()
        testCoordinatorDefersMarkedTextStyling()
        testCoordinatorStylesOnlyAfterCompletedTextChange()
        testScopedMarkdownAndTasks()
        testMarkdownCanBeRemovedIncrementally()
        testMarkdownLinks()
        testStaleLinkAttributesAreCleared()
        testLongNotePlanningStaysLocal()
        testTextDirectionConfiguration()
        testLegacyArchiveDefaultsToAutomaticDirection()
        testTextDirectionDatabaseMigration()

        guard failures == 0 else {
            fputs("EditorStyleEngineTests: \(failures) failure(s)\n", stderr)
            exit(1)
        }
        print("EditorStyleEngineTests: all checks passed")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        guard !condition() else { return }
        failures += 1
        fputs("\(file):\(line): failure: \(message)\n", stderr)
    }

    private static func testTextDirectionConfiguration() {
        let source = "English العربية עברית"
        let tv = makeTextView(source)
        let selection = NSRange(location: 4, length: 3)
        tv.setSelectedRange(selection)

        for direction in NoteTextDirection.allCases {
            NoteTextView.applyTextDirection(direction, to: tv)
            _ = EditorStyleEngine.apply(
                to: tv,
                ranges: [NSRange(location: 0, length: (source as NSString).length)],
                revealing: nil,
                ink: .textColor,
                size: 13.5,
                markdownEnabled: true,
                textDirection: direction,
                bodyFont: { NSFont.systemFont(ofSize: $0) },
                isCompletedTask: { _ in false })
            let expectedParagraphDirection: NSWritingDirection =
                direction == .automatic ? .leftToRight : direction.writingDirection
            let expectedParagraphAlignment: NSTextAlignment =
                direction == .automatic ? .left : direction.alignment
            check(tv.baseWritingDirection == expectedParagraphDirection,
                  "text view must apply \(direction.title) as its base writing direction")
            check(tv.alignment == expectedParagraphAlignment,
                  "text view must apply \(direction.title) alignment")
            let paragraph = tv.textStorage?.attribute(.paragraphStyle, at: 0,
                                                       effectiveRange: nil) as? NSParagraphStyle
            check(paragraph?.baseWritingDirection == expectedParagraphDirection,
                  "restyling must preserve \(direction.title) writing direction")
            check(paragraph?.alignment == expectedParagraphAlignment,
                  "restyling must preserve \(direction.title) paragraph alignment")
            check(tv.string == source, "changing direction must not mutate note text")
            check(tv.selectedRange() == selection,
                  "changing direction must preserve the editor selection")
        }

        let mixedParagraphs = "  123 مرحبا بالعالم\n... Hello world\n# שלום עולם"
        let mixed = makeTextView(mixedParagraphs)
        _ = EditorStyleEngine.apply(
            to: mixed,
            ranges: [NSRange(location: 0, length: (mixedParagraphs as NSString).length)],
            revealing: nil,
            ink: .textColor,
            size: 13.5,
            markdownEnabled: true,
            textDirection: .automatic,
            bodyFont: { NSFont.systemFont(ofSize: $0) },
            isCompletedTask: { _ in false })

        // The live wrapper applies this after the initial style pass. Automatic
        // must leave the per-paragraph results intact rather than replacing
        // them with NSTextView's locale-based natural alignment.
        NoteTextView.applyTextDirection(.automatic, to: mixed)

        let ns = mixedParagraphs as NSString
        let arabic = mixed.textStorage?.attribute(.paragraphStyle, at: 0,
                                                   effectiveRange: nil) as? NSParagraphStyle
        let englishLocation = ns.range(of: "Hello").location
        let english = mixed.textStorage?.attribute(.paragraphStyle, at: englishLocation,
                                                    effectiveRange: nil) as? NSParagraphStyle
        let hebrewLocation = ns.range(of: "שלום").location
        let hebrew = mixed.textStorage?.attribute(.paragraphStyle, at: hebrewLocation,
                                                   effectiveRange: nil) as? NSParagraphStyle
        check(arabic?.baseWritingDirection == .rightToLeft && arabic?.alignment == .right,
              "Automatic must resolve an Arabic paragraph from its first strong character")
        check(english?.baseWritingDirection == .leftToRight && english?.alignment == .left,
              "Automatic must resolve an English paragraph from its first strong character")
        check(hebrew?.baseWritingDirection == .rightToLeft && hebrew?.alignment == .right,
              "Automatic must resolve a Hebrew paragraph after neutral Markdown punctuation")
    }

    private struct LegacyStickyNote: Codable {
        var id = "legacy"
        var title = ""
        var body = "مرحبا"
        var color = 0
        var colorName = "Lemon"
        var created = Date(timeIntervalSince1970: 1)
        var modified = Date(timeIntervalSince1970: 2)
        var archived = false
        var order = 0.0
    }

    private static func testLegacyArchiveDefaultsToAutomaticDirection() {
        do {
            let data = try JSONEncoder().encode(LegacyStickyNote())
            let decoded = try JSONDecoder().decode(StickyNote.self, from: data)
            check(decoded.textDirection == nil,
                  "archives created before direction support must still decode")
            check(decoded.note.textDirection == .automatic,
                  "legacy archives must import with automatic direction")
        } catch {
            check(false, "legacy archive decoding failed: \(error)")
        }
    }

    private static func testTextDirectionDatabaseMigration() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noty-migration-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("notes.db")
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            var db: OpaquePointer?
            guard sqlite3_open(url.path, &db) == SQLITE_OK else {
                check(false, "test database must open")
                return
            }
            let legacySchema = """
            CREATE TABLE notes (
              id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', body BLOB NOT NULL,
              color INTEGER NOT NULL DEFAULT 0, created REAL NOT NULL,
              modified REAL NOT NULL, archived INTEGER NOT NULL DEFAULT 0,
              sort_order REAL NOT NULL DEFAULT 0, pinned INTEGER NOT NULL DEFAULT 0
            );
            """
            check(sqlite3_exec(db, legacySchema, nil, nil, nil) == SQLITE_OK,
                  "legacy schema setup must succeed")
            sqlite3_close(db)

            let migratedStore = Store(dbURL: url)
            _ = migratedStore

            db = nil
            guard sqlite3_open(url.path, &db) == SQLITE_OK else {
                check(false, "migrated database must reopen")
                return
            }
            defer { sqlite3_close(db) }

            check(sqlite3_exec(db,
                               "INSERT INTO notes (id,body,created,modified) VALUES ('legacy',X'00',1,1);",
                               nil, nil, nil) == SQLITE_OK,
                  "rows written after migration must receive the direction default")
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db,
                                     "SELECT text_direction FROM notes WHERE id='legacy';",
                                     -1, &statement, nil) == SQLITE_OK else {
                check(false, "migrated direction column must be queryable")
                return
            }
            defer { sqlite3_finalize(statement) }
            check(sqlite3_step(statement) == SQLITE_ROW,
                  "migrated database must return the inserted row")
            let raw = sqlite3_column_text(statement, 0).map { String(cString: $0) }
            check(raw == NoteTextDirection.automatic.rawValue,
                  "existing databases must default migrated notes to automatic direction")
        } catch {
            check(false, "migration test setup failed: \(error)")
        }
    }

    private static func testSingleCharacterScope() {
        let text = "alpha\nbeta gamma\ndelta\n" as NSString
        let edit = NSRange(location: text.range(of: "gamma").location + 2, length: 1)
        let ranges = EditorStyleEngine.affectedLineRanges(for: [edit], in: text)
        let expected = text.lineRange(for: edit)
        check(ranges == [expected], "a character edit must style only its line")
    }

    private static func testNewlineBoundaries() {
        let inserted = "alpha\nbeta" as NSString
        let insertion = NSRange(location: 5, length: 1)
        let insertedRanges = EditorStyleEngine.affectedLineRanges(for: [insertion], in: inserted)
        check(insertedRanges == [NSRange(location: 0, length: inserted.length)],
              "newline insertion must include both resulting lines")

        let deleted = "alphabeta\nend" as NSString
        let deletion = NSRange(location: 5, length: 0)
        let deletedRanges = EditorStyleEngine.affectedLineRanges(for: [deletion], in: deleted)
        check(deletedRanges == [deleted.lineRange(for: deletion)],
              "newline deletion must include the merged line")
    }

    private static func testDistantRangesStayDisjoint() {
        let text = "first\nsecond\nthird\nfourth\n" as NSString
        let first = NSRange(location: text.range(of: "first").location + 2, length: 1)
        let fourth = NSRange(location: text.range(of: "fourth").location + 2, length: 1)
        let ranges = EditorStyleEngine.affectedLineRanges(for: [first, fourth], in: text)
        check(ranges.count == 2, "distant edited lines must not absorb untouched lines")
        check(NSMaxRange(ranges[0]) <= ranges[1].location,
              "distant planned ranges must remain ordered and disjoint")
    }

    private static func testUTF16Ranges() {
        let text = "😀 emoji\n中文输入\nlast" as NSString
        let cjk = text.range(of: "输")
        let ranges = EditorStyleEngine.affectedLineRanges(for: [cjk], in: text)
        check(ranges.count == 1, "CJK edit must produce one line range")
        check(ranges.allSatisfy { $0.location >= 0 && NSMaxRange($0) <= text.length },
              "emoji/CJK ranges must stay inside UTF-16 storage bounds")
        check(EditorStyleEngine.lineRange(containing: Int.max, in: text).location <= text.length,
              "out-of-bounds caret locations must clamp to EOF")
    }

    private static func testMarkedTextAccumulation() {
        let text = "compose 中文 here" as NSString
        var edits = EditorEditAccumulator()
        edits.record(NSRange(location: 8, length: 1))
        check(edits.consume(in: text, hasMarkedText: true).isEmpty,
              "marked text must not release style ranges")
        check(edits.hasPendingEdits, "marked text must retain its dirty range")
        edits.record(NSRange(location: 8, length: 2))
        let committed = edits.consume(in: text, hasMarkedText: false)
        check(!committed.isEmpty, "composition commit must release accumulated ranges")
        check(!edits.hasPendingEdits, "composition commit must clear accumulated ranges")
    }

    private final class TextBox {
        var value: String
        init(_ value: String) { self.value = value }
    }

    private static func testCoordinatorDefersMarkedTextStyling() {
        _ = NSApplication.shared
        let box = TextBox("prefix ")
        let binding = Binding<String>(get: { box.value }, set: { box.value = $0 })
        let parent = NoteTextView(text: binding,
                                  ink: .textColor,
                                  bridge: EditorBridge(),
                                  autofocus: false,
                                  fontSize: 13.5,
                                  markdownEnabled: true)
        let coordinator = NoteTextView.Coordinator(parent)
        let tv = makeTaskTextView(box.value)
        tv.delegate = coordinator
        coordinator.attach(to: tv)
        tv.setSelectedRange(NSRange(location: tv.string.utf16.count, length: 0))

        tv.setMarkedText("zhongwen",
                         selectedRange: NSRange(location: 8, length: 0),
                         replacementRange: NSRange(location: NSNotFound, length: 0))
        check(tv.hasMarkedText(), "AppKit test setup must create a marked range")
        let marked = tv.markedRange()
        check(marked.location != NSNotFound && marked.length > 0,
              "marked-text setup must expose a valid UTF-16 range")
        guard marked.location != NSNotFound, marked.length > 0,
              let storage = tv.textStorage else { return }

        storage.addAttribute(.notyHidden, value: true, range: marked)
        let compositionSelection = tv.selectedRange()
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: tv))
        check(tv.hasMarkedText(), "coordinator must not commit an active composition")
        check(tv.markedRange() == marked, "coordinator must not move the marked range")
        check(tv.selectedRange() == compositionSelection,
              "coordinator must not move selection during composition")
        check(storage.attribute(.notyHidden, at: marked.location,
                                effectiveRange: nil) != nil,
              "coordinator must not run styling while marked text exists")

        tv.unmarkText()
        let committedSelection = tv.selectedRange()
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: tv))
        check(!tv.hasMarkedText(), "composition must be committed before deferred styling")
        check(tv.selectedRange() == committedSelection,
              "deferred styling must preserve the committed caret")
        check(storage.attribute(.notyHidden, at: marked.location,
                                effectiveRange: nil) == nil,
              "composition commit must process the accumulated dirty range")
        check(box.value == tv.string, "committed marked text must reach the SwiftUI binding")
    }

    private static func testCoordinatorStylesOnlyAfterCompletedTextChange() {
        _ = NSApplication.shared
        let box = TextBox("")
        let binding = Binding<String>(get: { box.value }, set: { box.value = $0 })
        let parent = NoteTextView(text: binding,
                                  ink: .textColor,
                                  bridge: EditorBridge(),
                                  autofocus: false,
                                  fontSize: 13.5,
                                  markdownEnabled: true)
        let coordinator = NoteTextView.Coordinator(parent)
        let tv = makeTaskTextView("")
        tv.delegate = coordinator
        coordinator.attach(to: tv)
        guard let storage = tv.textStorage else {
            check(false, "test text view must have text storage")
            return
        }

        let firstInput = "测试"
        let inserted = NSRange(location: 0, length: (firstInput as NSString).length)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: firstInput)
        storage.addAttribute(.notyHidden, value: true, range: inserted)
        tv.setSelectedRange(NSRange(location: inserted.length, length: 0))

        coordinator.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: tv))
        check(storage.attribute(.notyHidden, at: 0, effectiveRange: nil) != nil,
              "selection changes during an edit must not style the unfinished TextKit state")

        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: tv))
        check(storage.attribute(.notyHidden, at: 0, effectiveRange: nil) == nil,
              "the completed text-change notification must reveal first-line input")
        check(box.value == firstInput, "first-line input must reach the SwiftUI binding")
        check(Note.derivedTitle(from: box.value) == firstInput,
              "visible first-line input and the derived title must use the same source")

        for token in ["\n", "第", "二", "行", "\n", "第", "三", "行"] {
            let end = storage.length
            storage.replaceCharacters(in: NSRange(location: end, length: 0), with: token)
            tv.setSelectedRange(NSRange(location: storage.length, length: 0))
            coordinator.textViewDidChangeSelection(
                Notification(name: NSTextView.didChangeSelectionNotification, object: tv))
            coordinator.textDidChange(
                Notification(name: NSText.didChangeNotification, object: tv))
        }
        check(box.value == "测试\n第二行\n第三行",
              "rapid early-line edits must all reach the SwiftUI binding")

        guard let layout = tv.layoutManager, let container = tv.textContainer else {
            check(false, "test text view must have a TextKit layout stack")
            return
        }
        layout.ensureLayout(for: container)
        let visibleCharacters = NSRange(location: 0, length: storage.length)
        let glyphs = layout.glyphRange(forCharacterRange: visibleCharacters,
                                       actualCharacterRange: nil)
        check(glyphs.length >= 8, "the first three lines must all generate glyphs")
        for index in glyphs.location..<NSMaxRange(glyphs) {
            check(!layout.propertyForGlyph(at: index).contains(.null),
                  "early-line input glyphs must not retain the hidden-marker property")
        }
    }

    private static func testScopedMarkdownAndTasks() {
        let source = "plain\n# Heading\n**bold** *italic* `code` ~~gone~~\n> quote\n- bullet\n☑ done\noutside"
        let text = source as NSString
        let tv = makeTextView(source)
        guard let storage = tv.textStorage else {
            check(false, "test text view must have text storage")
            return
        }

        let styledStart = text.range(of: "# Heading").location
        let taskLine = text.lineRange(for: text.range(of: "☑ done"))
        let styled = NSRange(location: styledStart, length: NSMaxRange(taskLine) - styledStart)
        let outside = text.range(of: "outside")
        storage.addAttribute(.backgroundColor, value: NSColor.systemRed, range: outside)
        let selection = NSRange(location: text.range(of: "bold").location + 2, length: 0)
        tv.setSelectedRange(selection)

        let active = text.lineRange(for: text.range(of: "plain"))
        let original = tv.string
        let applied = apply(to: tv, ranges: [styled], revealing: active, markdown: true)

        check(applied == [styled], "style engine must report the scoped range it applied")
        check(tv.string == original, "styling must not mutate plain-text source")
        check(tv.selectedRange() == selection, "styling must not rewrite selection")
        check((storage.attribute(.backgroundColor, at: outside.location,
                                 effectiveRange: nil) as? NSColor) == NSColor.systemRed,
              "styling must not alter attributes outside its range")

        let heading = text.range(of: "Heading")
        let headingFont = storage.attribute(.font, at: heading.location,
                                            effectiveRange: nil) as? NSFont
        check((headingFont?.pointSize ?? 0) > 13.5, "heading must retain its larger font")

        let bold = text.range(of: "bold")
        let boldFont = storage.attribute(.font, at: bold.location,
                                         effectiveRange: nil) as? NSFont
        check(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) == true,
              "bold Markdown must retain a bold font")

        let italic = text.range(of: "italic")
        check(storage.attribute(.obliqueness, at: italic.location,
                                effectiveRange: nil) != nil,
              "italic Markdown must retain obliqueness")

        let code = text.range(of: "code")
        check(storage.attribute(.backgroundColor, at: code.location,
                                effectiveRange: nil) != nil,
              "code Markdown must retain its background")

        let gone = text.range(of: "gone")
        check(storage.attribute(.strikethroughStyle, at: gone.location,
                                effectiveRange: nil) != nil,
              "strikethrough Markdown must retain its decoration")
        check(storage.attribute(.strikethroughStyle, at: taskLine.location,
                                effectiveRange: nil) != nil,
              "completed tasks must remain struck through")

        let openingBoldMarker = text.range(of: "**bold").location
        check(storage.attribute(.notyHidden, at: openingBoldMarker,
                                effectiveRange: nil) != nil,
              "Markdown markers outside the caret line must stay hidden")
    }

    private static func testMarkdownCanBeRemovedIncrementally() {
        let source = "**bold**\nplain"
        let text = source as NSString
        let tv = makeTextView(source)
        let line = text.lineRange(for: text.range(of: "bold"))
        _ = apply(to: tv, ranges: [line], revealing: nil, markdown: true)
        check(tv.textStorage?.attribute(.notyHidden, at: 0, effectiveRange: nil) != nil,
              "setup must add hidden Markdown markers")
        _ = apply(to: tv, ranges: [line], revealing: nil, markdown: false)
        check(tv.textStorage?.attribute(.notyHidden, at: 0, effectiveRange: nil) == nil,
              "turning Markdown off must remove hidden markers in the styled range")
    }

    private static func testMarkdownLinks() {
        let source = "see [the repo](https://github.com/aimen08/noty) here\nplain"
        let text = source as NSString
        let tv = makeTextView(source)
        guard let storage = tv.textStorage else {
            check(false, "test text view must have text storage")
            return
        }

        let line = text.lineRange(for: text.range(of: "repo"))
        _ = apply(to: tv, ranges: [line], revealing: nil, markdown: true)

        let label = text.range(of: "the repo")
        check(storage.attribute(.underlineStyle, at: label.location,
                                effectiveRange: nil) != nil,
              "a link label must be underlined")
        let target = storage.attribute(.link, at: label.location, effectiveRange: nil) as? URL
        check(target?.absoluteString == "https://github.com/aimen08/noty",
              "a link label must carry its destination")

        check(storage.attribute(.notyHidden, at: text.range(of: "[the").location,
                                effectiveRange: nil) != nil,
              "the opening bracket must be hidden off the caret line")
        check(storage.attribute(.notyHidden, at: text.range(of: "github").location,
                                effectiveRange: nil) != nil,
              "the URL must be hidden off the caret line")
        check(storage.attribute(.notyHidden, at: label.location,
                                effectiveRange: nil) == nil,
              "the label itself must never be hidden")

        _ = apply(to: tv, ranges: [line], revealing: line, markdown: true)
        check(storage.attribute(.notyHidden, at: text.range(of: "github").location,
                                effectiveRange: nil) == nil,
              "the caret line must reveal the URL so it can be edited")

        // A note is text, and text can name any scheme. Only the three we open
        // ever become clickable.
        let hostile = "[run](javascript:alert(1)) and [file](file:///etc/passwd)"
        let hostileText = hostile as NSString
        let hostileView = makeTextView(hostile)
        _ = apply(to: hostileView, ranges: [NSRange(location: 0, length: hostileText.length)],
                  revealing: nil, markdown: true)
        check(hostileView.textStorage?.attribute(
                .link, at: hostileText.range(of: "run").location, effectiveRange: nil) == nil,
              "a javascript: link must be styled but never clickable")
        check(hostileView.textStorage?.attribute(
                .link, at: hostileText.range(of: "file").location, effectiveRange: nil) == nil,
              "a file: link must be styled but never clickable")
        check(EditorStyleEngine.openableURL("mailto:someone@example.com") != nil,
              "mailto must stay openable")
    }

    private static func testStaleLinkAttributesAreCleared() {
        // Styling is line-scoped: nothing else will ever come back to this line
        // to tidy up, so breaking the syntax has to clear the attributes itself.
        let tv = makeTextView("[label](https://example.com)\nplain")
        guard let storage = tv.textStorage else {
            check(false, "test text view must have text storage")
            return
        }
        let whole = NSRange(location: 0, length: (tv.string as NSString).length)
        let line = (tv.string as NSString).lineRange(for: NSRange(location: 0, length: 0))
        _ = apply(to: tv, ranges: [line], revealing: nil, markdown: true)
        check(storage.attribute(.link, at: 1, effectiveRange: nil) != nil,
              "setup must produce a link")

        storage.replaceCharacters(in: whole, with: "label https://example.com\nplain")
        let broken = (tv.string as NSString).lineRange(for: NSRange(location: 0, length: 0))
        _ = apply(to: tv, ranges: [broken], revealing: nil, markdown: true)
        check(storage.attribute(.link, at: 0, effectiveRange: nil) == nil,
              "breaking the syntax must clear .link")
        check(storage.attribute(.underlineStyle, at: 0, effectiveRange: nil) == nil,
              "breaking the syntax must clear the underline")
    }

    private static func testLongNotePlanningStaysLocal() {
        let line = "a moderately long line of note text\n"
        let source = String(repeating: line, count: 20_000)
        let text = source as NSString
        let edit = NSRange(location: text.length / 2, length: 1)
        let ranges = EditorStyleEngine.affectedLineRanges(for: [edit], in: text)
        let processed = ranges.reduce(0) { $0 + $1.length }
        check(processed <= line.utf16.count * 2,
              "single-character work in a long note must stay paragraph-local")
        check(processed * 1_000 < text.length,
              "long-note planning must not approach full-document work")
    }

    private static func makeTextView(_ source: String) -> NSTextView {
        let storage = NSTextStorage(string: source)
        let layout = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        return NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 500),
                          textContainer: container)
    }

    private static func makeTaskTextView(_ source: String) -> TaskTextView {
        let storage = NSTextStorage(string: source)
        let layout = HidingLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        return TaskTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 500),
                            textContainer: container)
    }

    @discardableResult
    private static func apply(to tv: NSTextView, ranges: [NSRange],
                              revealing active: NSRange?, markdown: Bool) -> [NSRange] {
        EditorStyleEngine.apply(to: tv,
                                ranges: ranges,
                                revealing: active,
                                ink: .textColor,
                                size: 13.5,
                                markdownEnabled: markdown,
                                bodyFont: { NSFont.systemFont(ofSize: $0) },
                                isCompletedTask: { $0.first == "☑" })
    }
}
