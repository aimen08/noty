import AppKit
import Foundation
import SQLite3
import SwiftUI

enum PersistenceTests {
    static func run(check: (Bool, String) -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noty-persistence-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try testSharedEditing(directory, check)
            try testCryptoFailures(directory, check)
            try testExport(directory, check)
            try testArchives(directory, check)
            testTasks(check)
        } catch { check(false, "Persistence regression failed: \(error)") }
    }

    private static func mustThrow(_ message: String, _ check: (Bool, String) -> Void,
                                  _ operation: () throws -> Void) {
        do { try operation(); check(false, message) }
        catch { /* Expected failure. */ }
    }

    private static func testSharedEditing(_ dir: URL, _ check: (Bool, String) -> Void) throws {
        let url = dir.appendingPathComponent("shared.db")
        let storage = Store(dbURL: url, keyURL: dir.appendingPathComponent("shared.key"))
        var errors = 0
        let model = NoteStore(store: storage, seedWelcome: false, onError: { _ in errors += 1 })
        let note = model.create(body: "Initial")
        let binding = Binding<String>(get: { model.note(id: note.id)!.body },
                                      set: { model.updateBody(id: note.id, body: $0) })
        let parent = NoteTextView(text: binding, ink: .textColor, bridge: EditorBridge(),
                                  autofocus: false, fontSize: 13.5, markdownEnabled: false,
                                  textDirection: .automatic, styleToken: "test")
        let editor = NSTextView()
        editor.string = "Initial"
        let coordinator = NoteTextView.Coordinator(parent)
        coordinator.attach(to: editor)
        editor.string = "Edited in deck"
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        check(model.note(id: note.id)?.body == "Edited in deck",
              "native editor changes must reach shared state before the save delay")
        check(model.unsavedIDs.contains(note.id), "pending writes must be marked unsaved")
        // Quick Capture reads the current shared value, including pending editor input.
        model.updateBody(id: note.id, body: model.note(id: note.id)!.body + "\nCaptured")
        coordinator.synchronize(editor)
        check(editor.string == "Edited in deck\nCaptured", "open editors must receive external changes")
        check(model.flush(id: note.id), "closing an editor must flush the latest shared value")
        check(try storage.load().first?.body == editor.string, "flush must preserve appended content")

        var db: OpaquePointer?
        check(sqlite3_open(url.path, &db) == SQLITE_OK, "lock connection must open")
        defer { sqlite3_close(db) }
        check(sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK, "test must lock writes")
        model.updateBody(id: note.id, body: "Keep this unsaved edit")
        check(!model.flushAll(), "failed writes must prevent a successful quit flush")
        check(model.unsavedIDs.contains(note.id) && errors > 0, "save errors must be visible and remain dirty")
        check(try storage.load().first?.body == "Edited in deck\nCaptured", "failed save must leave disk content intact")
        model.delete(id: note.id)
        check(model.note(id: note.id) != nil && model.pendingUndo == nil,
              "failed deletes must leave the note in the model")
        check(sqlite3_exec(db, "ROLLBACK", nil, nil, nil) == SQLITE_OK, "test must unlock writes")
        check(model.flushAll() && model.unsavedIDs.isEmpty, "retry must clear unsaved state after success")
        check(try storage.load().first?.body == "Keep this unsaved edit", "retry must persist the retained edit")
        model.updateTitle(id: note.id, title: "Keep this unsaved edit")
        check(model.flushAll(), "custom title must save")
        let reopened = NoteStore(store: storage, seedWelcome: false, onError: { _ in errors += 1 })
        check(reopened.note(id: note.id)?.title == "Keep this unsaved edit",
              "custom titles equal to the body must survive reopening")
    }

    private static func testCryptoFailures(_ dir: URL, _ check: (Bool, String) -> Void) throws {
        let keyURL = dir.appendingPathComponent("crypto.key")
        let cipher = Crypto(keyURL: keyURL, allowCreation: true)
        let sealed = try cipher.seal("secret")
        check(try cipher.open(sealed) == "secret", "encryption must round-trip")
        let attributes = try FileManager.default.attributesOfItem(atPath: keyURL.path)
        check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              "a newly created key must be private from creation")
        let originalKey = try Data(contentsOf: keyURL)
        let invalid = Data("invalid key".utf8)
        try invalid.write(to: keyURL)
        let invalidCipher = Crypto(keyURL: keyURL, allowCreation: true)
        mustThrow("an invalid key must not be replaced", check) { _ = try invalidCipher.seal("edit") }
        check(try Data(contentsOf: keyURL) == invalid, "invalid key bytes must remain untouched")
        let absent = dir.appendingPathComponent("absent.key")
        mustThrow("existing data must require its original key", check) {
            _ = try Crypto(keyURL: absent, allowCreation: false).seal("edit")
        }
        check(!FileManager.default.fileExists(atPath: absent.path), "missing existing key must not be regenerated")
        mustThrow("an unpersistable key must prevent encryption", check) {
            _ = try Crypto(keyURL: dir.appendingPathComponent("missing/child.key"), allowCreation: true).seal("edit")
        }
        try originalKey.write(to: keyURL)
        let url = dir.appendingPathComponent("corrupt.db")
        let storage = Store(dbURL: url, keyURL: keyURL)
        let note = Note(body: "original")
        try storage.upsert(note)
        var db: OpaquePointer?
        check(sqlite3_open(url.path, &db) == SQLITE_OK, "corruption fixture must open")
        defer { sqlite3_close(db) }
        check(sqlite3_exec(db, "UPDATE notes SET body=X'00'", nil, nil, nil) == SQLITE_OK,
              "corruption fixture must be installed")
        mustThrow("corruption must fail loading, not create a blank note", check) { _ = try storage.load() }
        mustThrow("a failed load must block writes to the original database", check) { try storage.upsert(note) }
        var reported = false
        let protected = NoteStore(store: storage, onError: { _ in reported = true })
        _ = protected.create(body: "replacement")
        check(reported && protected.notes.isEmpty, "failed startup must not seed or create replacement notes")

        let validURL = dir.appendingPathComponent("missing-key.db")
        let validStore = Store(dbURL: validURL, keyURL: keyURL)
        try validStore.upsert(note)
        let withoutKey = Store(dbURL: validURL, keyURL: absent)
        mustThrow("existing encrypted rows must never generate a replacement key", check) { _ = try withoutKey.load() }
        check(!FileManager.default.fileExists(atPath: absent.path), "loading must preserve the missing-key condition")
    }

    private static func testExport(_ dir: URL, _ check: (Bool, String) -> Void) throws {
        let original = dir.appendingPathComponent("Shopping.md")
        try "existing file".write(to: original, atomically: true, encoding: .utf8)
        var used = Set<String>()
        let first = try Transfer.writeUniqueFile("new note", named: "Shopping", ext: "md", directory: dir, used: &used)
        let second = try Transfer.writeUniqueFile("another note", named: "shopping", ext: "md", directory: dir, used: &used)
        check(first.lastPathComponent == "Shopping-2.md" && second.lastPathComponent == "shopping-3.md",
              "exports must avoid existing names and case-insensitive batch collisions")
        check(try String(contentsOf: original, encoding: .utf8) == "existing file", "export must preserve existing content")
        let link = dir.appendingPathComponent("Link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        _ = try Transfer.writeUniqueFile("link note", named: "Link", ext: "md", directory: dir, used: &used)
        check(try String(contentsOf: original, encoding: .utf8) == "existing file", "export must not follow existing symlinks")
    }

    private static func testArchives(_ dir: URL, _ check: (Bool, String) -> Void) throws {
        let original = Note(body: "Original title\nBody", color: 3, archived: true, pinned: true,
                            textDirection: .rightToLeft, order: 12)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(StickyArchive(notes: [StickyNote(original)]))
        var restored = try Transfer.decodeArchive(data)[0]
        restored.body = "Changed title\nBody"
        check(restored.pinned && restored.archived && restored.textDirection == .rightToLeft,
              "archives must preserve pin, archive and writing direction")
        check(restored.title.isEmpty && restored.displayTitle == "Changed title",
              "automatic archive titles must continue following the body")
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var notes = object["notes"] as! [[String: Any]]
        notes[0].removeValue(forKey: "pinned")
        notes[0].removeValue(forKey: "textDirection")
        object["version"] = 2
        object["notes"] = notes
        let legacy = try Transfer.decodeArchive(JSONSerialization.data(withJSONObject: object))[0]
        check(!legacy.pinned && legacy.textDirection == .automatic, "older archives must remain readable")
        notes[0]["color"] = 2147483648
        object["notes"] = notes
        mustThrow("oversized imported colours must be rejected before storage", check) {
            _ = try Transfer.decodeArchive(JSONSerialization.data(withJSONObject: object))
        }
        let storage = Store(dbURL: dir.appendingPathComponent("color.db"), keyURL: dir.appendingPathComponent("color.key"))
        mustThrow("storage must reject overflowing colors even outside import", check) {
            try storage.upsert(Note(color: Int.max))
        }
        let model = NoteStore(store: storage, seedWelcome: false, onError: { _ in })
        let first = Note(body: "First", order: 0)
        let second = Note(body: "Second", order: 1)
        check(model.ingest([second, first]) == 2, "valid archive notes must import")
        check(model.active.map(\.body) == ["First", "Second"], "archive import must preserve relative deck order")
    }

    private static func testTasks(_ check: (Bool, String) -> Void) {
        let markdown = "# Shopping\n- [ ] Milk\n- [x] Bread\n  * [X] Nested\nText ☐ symbol"
        let native = "# Shopping\n☐ Milk\n☑ Bread\n  ☑ Nested\nText ☐ symbol"
        check(Tasks.fromMarkdown(markdown) == native, "all checklist lines must import beneath a heading")
        check(Tasks.toMarkdown(native) == "# Shopping\n- [ ] Milk\n- [x] Bread\n  - [x] Nested\nText ☐ symbol",
              "task export must preserve inline checkbox symbols")
        check(Tasks.fromMarkdown("- [ ] One\r\n- [x] Two") == "☐ One\r\n☑ Two",
              "checklist import must handle Windows line endings")
    }
}
