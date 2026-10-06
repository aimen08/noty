import AppKit
import Foundation
import SQLite3
import SwiftUI

enum OrganizationTests {
    static func run(check: (Bool, String) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("noty-organize-\(UUID())")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let db = Store(dbURL: dir.appendingPathComponent("notes.db"), keyURL: dir.appendingPathComponent("key"))
            let store = NoteStore(store: db, seedWelcome: false, onError: { _ in })
            let first = store.create(body: "Release planning\n☐ Review", title: "Roadmap")
            let second = store.create(body: "Design notes")
            let ids: Set<String> = [first.id, second.id]
            check(store.organize(ids: ids, project: "  Noty  ", tags: ["设计", "Review", "review", " "]),
                  "batch organization must save")
            let loaded = try db.load()
            check(loaded.count == 2 && loaded.allSatisfy { $0.project == "Noty" && $0.tags == ["设计", "Review"] },
                  "project and deduplicated tags must survive database reopen")
            store.organize(ids: [first.id], tags: ["优先"], addingTags: true)
            check(store.note(id: first.id)?.tags == ["设计", "Review", "优先"], "batch add must retain prior tags")
            store.organize(ids: [first.id], archived: true)
            check(NoteQuery(text: "Roadmap 优先").results(in: store.notes).map(\.id) == [first.id],
                  "default search must span archived notes and AND words across content and tags")
            check(NoteQuery(scope: .active).results(in: store.notes).map(\.id) == [second.id], "active must exclude archive")
            check(NoteQuery(project: "Noty", tag: "review").results(in: store.notes).count == 2,
                  "project and case-insensitive tag filters must combine")
            check(NoteQuery(project: "Elsewhere").results(in: store.notes).isEmpty, "filters must not leak other projects")

            // Invalid writes must roll back the entire batch, not leave the first
            // note saved with a new project while a later row fails validation.
            var a = store.note(id: first.id)!, b = store.note(id: second.id)!
            a.project = "Should roll back"; b.color = Int.max
            do { try db.transaction(upserting: [a, b]); check(false, "invalid batch must fail") }
            catch { /* expected */ }
            check(try db.load().allSatisfy { $0.project == "Noty" }, "transaction must roll back earlier rows")

            check(store.trash(ids: ids), "batch trash must save")
            check(store.active.isEmpty && store.archived.isEmpty && store.trash.count == 2,
                  "trash must be separate from active and archive")
            let reopened = NoteStore(store: db, seedWelcome: false, onError: { _ in })
            check(reopened.trash.count == 2, "trash must survive relaunch")
            check(NoteQuery().results(in: reopened.notes).isEmpty, "all search must exclude trash")
            check(NoteQuery(scope: .trash, text: "Roadmap").results(in: reopened.notes).count == 1,
                  "trash must be searchable")
            store.undoDelete()
            check(store.trash.isEmpty && store.archived.count == 1 && store.active.count == 1,
                  "batch undo must restore all notes with their former archive state")
            let merged = store.merge(ids: ids)
            check(merged?.body.contains("Release planning") == true && merged?.body.contains("Design notes") == true,
                  "merge must preserve both bodies")
            check(merged?.project == "Noty" && merged?.tags.contains("优先") == true && store.trash.count == 2,
                  "merge must combine organization and retain originals in trash")
            check(store.permanentlyDelete(ids: ids) && store.notes.count == 1, "purge must only remove selected trash")
            check(store.permanentlyDelete(ids: [merged!.id]) && store.notes.count == 1,
                  "permanent delete must never remove a living note")

            try importAndFormats(dir, check)
            trashSync(check)
            try syncWithTrash(dir, check)
            readOnlyEditor(check)
            floatingWindows(check)
        } catch { check(false, "Organization regression: \(error)") }
    }

    private static func importAndFormats(_ dir: URL, _ check: (Bool, String) -> Void) throws {
        let db = Store(dbURL: dir.appendingPathComponent("import.db"), keyURL: dir.appendingPathComponent("import.key"))
        let store = NoteStore(store: db, seedWelcome: false, onError: { _ in })
        var original = Note(title: "Release", body: "Keep both versions", project: "项目: One", tags: ["设计", "quoted \"tag\""])
        check(store.importNotes([original, original]).added == 1, "one import must skip exact duplicates inside the batch")
        let repeatImport = store.importNotes([original])
        check(repeatImport.added == 0 && repeatImport.skipped == 1 && repeatImport.failed == 0,
                  "repeat import must skip without reporting an error")
        original.body = "An older or newer different version"
        check(store.importNotes([original]).added == 1 && Set(store.notes.map(\.id)).count == 2,
                  "same identity with different content must be retained separately")
        var other = original; other.id = UUID().uuidString; other.project = "Another project"
        check(store.importNotes([other]).added == 1, "dedup must not discard identical notes from distinct projects")

        original.deletedAt = Date(timeIntervalSince1970: 1000)
        let document = NoteDocument.parse(NoteDocument.render(original), fallbackTitle: "").note
        check(document.project == original.project && document.tags == original.tags && document.deletedAt == original.deletedAt,
                  "Markdown metadata must round-trip Unicode, quotes, colons and deletion time")
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let archive = try Transfer.decodeArchive(enc.encode(StickyArchive(notes: [StickyNote(original)])))[0]
        check(archive.project == original.project && archive.tags == original.tags && archive.isTrashed,
                  "archive must preserve new organization and trash metadata")
        var legacy = try JSONSerialization.jsonObject(with: enc.encode(StickyArchive(notes: [StickyNote(original)]))) as! [String: Any]
        var rows = legacy["notes"] as! [[String: Any]]
        for field in ["project", "tags", "deletedAt"] { rows[0].removeValue(forKey: field) }
        legacy["notes"] = rows; legacy["version"] = 3
        let old = try Transfer.decodeArchive(JSONSerialization.data(withJSONObject: legacy))[0]
        check(old.project.isEmpty && old.tags.isEmpty && !old.isTrashed, "version 3 archives must use safe defaults")

        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 10, height: 10).fill(); image.unlockFocus()
        let imageID = ImageStore.save(image: image)!
        let secondID = ImageStore.save(data: ImageStore.data(id: imageID)!, ext: "png")!
        defer { ImageStore.delete(ids: [imageID, secondID]) }
        let picture = Note(body: ImageStore.token(id: imageID, width: 200))
        let copy = Note(body: ImageStore.token(id: secondID, width: 200))
        let result = store.importNotes([picture, copy])
        check(result.added == 1 && result.skipped == 1, "same picture under remapped IDs must deduplicate")
        store.delete(id: picture.id)
        check(ImageStore.data(id: imageID) != nil, "moving a picture to trash must retain image data")
        check(store.restore(ids: [picture.id]), "trashed picture must restore")
    }

    private static func trashSync(_ check: (Bool, String) -> Void) {
        let trashed = Note(id: "trash", body: "Original", deletedAt: Date())
        let remote = SyncPlan.RemoteFile(fileName: "Trash.md", noteID: trashed.id,
                                        declaredModified: .distantPast, fileModified: .distantPast)
        let index = CloudSyncIndex()
        check(SyncPlan.actions(notes: [trashed], remote: [], unresolved: [], index: index).isEmpty,
                  "trash must not be pushed as a new note after losing its sync index")
        check(SyncPlan.actions(notes: [trashed], remote: [remote], unresolved: [], index: index)
              == [.deleteRemote(fileName: "Trash.md")], "persistent tombstone must delete remote instead of resurrecting locally")
        var restored = trashed; restored.deletedAt = nil
        check(SyncPlan.actions(notes: [restored], remote: [], unresolved: [], index: index)
              == [.push(noteID: restored.id, existingFileName: nil)], "restoring trash must make a note syncable again")
    }

    private static func floatingWindows(_ check: (Bool, String) -> Void) {
        _ = NSApplication.shared
        let store = NoteStore.shared
        let a = store.create(body: "Floating A"), b = store.create(body: "Floating B")
        let windows = FloatingNotes()
        windows.open(ids: [a.id, b.id])
        check(windows.noteIDs == [a.id, b.id], "opening a second note must leave both floating")
        windows.open(ids: [a.id])
        check(windows.noteIDs.count == 2, "reopening a note must focus, not duplicate its window")
        if let first = NSApp.windows.first(where: { $0.title == a.displayTitle }),
           let second = NSApp.windows.first(where: { $0.title == b.displayTitle }),
           let screen = first.screen {
            let original = first.frame, other = second.frame
            let defaultSize = Settings.floatingNoteSize
            check(first.collectionBehavior.contains(.fullScreenPrimary) && first.styleMask.contains(.resizable),
                  "each note must support native full screen")
            windows.maximize(id: a.id)
            check(first.frame == screen.visibleFrame && second.frame == other,
                  "maximizing one note must fill the usable screen without moving another")
            check(Settings.floatingNoteSize == defaultSize,
                  "maximizing must not overwrite the preferred size of new notes")
            windows.maximize(id: a.id)
            check(first.frame == original && windows.noteIDs.count == 2,
                  "maximizing again must restore the same note's original frame without duplication")
            first.performClose(nil)
            check(windows.noteIDs == [b.id] && store.note(id: a.id)?.isTrashed == false,
                  "the native close button must release only its window, without deleting the note")
            windows.open(ids: [a.id])
        } else { check(false, "floating note windows must be discoverable for geometry checks") }
        store.updateBody(id: a.id, body: "Edited A")
        windows.close(id: a.id)
        check(windows.noteIDs == [b.id] && store.note(id: a.id)?.body == "Edited A",
                  "closing one floating note must save it and leave the other open")
        windows.closeAll()
        check(windows.noteIDs.isEmpty, "close all must release every note window")
        store.trash(ids: [a.id, b.id]); store.permanentlyDelete(ids: [a.id, b.id])
    }

    private static func readOnlyEditor(_ check: (Bool, String) -> Void) {
        var body = "☐ Preserve this task"
        let bridge = EditorBridge()
        var parent = NoteTextView(text: Binding(get: { body }, set: { body = $0 }),
                                  ink: .textColor, bridge: bridge, autofocus: false,
                                  editable: false)
        let coordinator = NoteTextView.Coordinator(parent)
        let storage = NSTextStorage(string: body)
        let layout = HidingLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 400, height: 600))
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let textView = TaskTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        check(textView.string == body, "read-only fixture must contain the original task")
        textView.isEditable = false
        textView.delegate = coordinator
        coordinator.attach(to: textView)
        bridge.textView = textView
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        bridge.toggleTaskLine()
        check(textView.string == body, "a checkbox action must not modify a read-only trash preview")
        textView.insertImageTokens([ImageStore.token(id: UUID().uuidString, width: nil)])
        check(textView.string == body, "image insertion must not modify a read-only trash preview")
        parent.editable = true
        coordinator.parent = parent
        textView.isEditable = true
        bridge.toggleTaskLine()
        check(textView.string == "☑ Preserve this task", "restored notes must remain editable")
    }

    private static func syncWithTrash(_ dir: URL, _ check: (Bool, String) -> Void) throws {
        let db = Store(dbURL: dir.appendingPathComponent("sync.db"), keyURL: dir.appendingPathComponent("sync.key"))
        let store = NoteStore(store: db, seedWelcome: false, onError: { _ in })
        let folder = SyncRunnerTests.FakeFolder()
        let enabled = Settings.cloudSyncEnabled
        Settings.cloudSyncEnabled = true
        defer { Settings.cloudSyncEnabled = enabled }
        let sync = CloudSync(folder: folder, store: store, indexURL: dir.appendingPathComponent("index.json"))
        let note = store.create(body: "Original text")
        store.organize(ids: [note.id], project: "Shared project", tags: ["tag"])
        sync.syncNow()
        guard let name = folder.files.keys.first else { check(false, "initial sync must write a note"); return }
        let mirrored = NoteDocument.parse(folder.files[name]!, fallbackTitle: "").note
        check(mirrored.project == "Shared project" && mirrored.tags == ["tag"], "sync must carry organization metadata")
        // A phone edit arrives at the same time as a local move to Trash.
        var remote = mirrored; remote.body = "Remote edit that must not vanish"
        folder.files[name] = NoteDocument.render(remote)
        folder.dates[name] = Date().addingTimeInterval(10)
        store.delete(id: note.id)
        sync.syncNow()
        check(folder.files.isEmpty && folder.conflicts.values.contains(where: { $0.contains(remote.body) }),
                  "deleting remotely must keep a concurrent phone edit in Conflicts")
        sync.syncNow()
        check(folder.files.isEmpty && store.trash.count == 1, "next sync must not republish trash")
        store.restore(ids: [note.id])
        sync.syncNow()
        check(folder.files.count == 1 && store.active.count == 1, "restoring must republish the note")
        folder.files.removeAll(); folder.dates.removeAll()
        sync.syncNow()
        check(store.trash.count == 1, "a remote deletion must retain a local recoverable copy")
        sync.syncNow()
        check(folder.files.isEmpty, "remote deletion must stay deleted on repeated passes")
    }
}
