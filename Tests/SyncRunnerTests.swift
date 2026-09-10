import Foundation

/// Drives the sync runner end to end against in-memory fakes. The runner is
/// where every data-loss defect of the first implementation lived, precisely
/// because it had no tests.
enum SyncRunnerTests {
    typealias Check = (Bool, String) -> Void

    // MARK: Fakes

    final class FakeFolder: SyncFolderGateway {
        var isAvailable = true
        var files: [String: String] = [:]
        var dates: [String: Date] = [:]
        /// Names present in the folder whose contents cannot be read this pass.
        var unresolved: Set<String> = []
        var conflicts: [String: String] = [:]
        var removed: [String] = []

        func ensureFolder() -> Bool { isAvailable }

        func scan() -> FolderScan {
            var out = FolderScan()
            for (name, _) in files where !unresolved.contains(name) {
                out.documents[name] = dates[name] ?? SyncRunnerTests.t0
            }
            out.unresolved = unresolved.intersection(Set(files.keys))
            return out
        }

        /// Recorded so a later task can prove a quiet pass reads nothing.
        var reads: [String] = []

        func read(_ fileName: String) -> String? {
            guard !unresolved.contains(fileName) else { return nil }
            reads.append(fileName)
            return files[fileName]
        }

        func modificationDate(of fileName: String) -> Date? { dates[fileName] }

        @discardableResult
        func write(_ text: String, named fileName: String) -> Bool {
            files[fileName] = text
            dates[fileName] = dates[fileName] ?? Date(timeIntervalSince1970: 1_757_000_000)
            return true
        }

        @discardableResult
        func remove(_ fileName: String) -> Bool {
            removed.append(fileName)
            files[fileName] = nil
            dates[fileName] = nil
            unresolved.remove(fileName)
            return true
        }

        @discardableResult
        func writeConflict(_ text: String, named fileName: String) -> Bool {
            conflicts[fileName] = text
            return true
        }

        /// Put a note in the folder exactly as the app would have written it.
        func place(_ note: Note, named fileName: String, at date: Date) {
            files[fileName] = NoteDocument.render(note)
            dates[fileName] = date
        }
    }

    final class FakeStore: NoteStoring {
        var notes: [Note] = []
        var deleted: [String] = []

        var active: [Note] { notes.filter { !$0.archived }.sorted { $0.order < $1.order } }
        func note(id: String) -> Note? { notes.first { $0.id == id } }

        func absorb(_ note: Note) {
            if let i = notes.firstIndex(where: { $0.id == note.id }) { notes[i] = note }
            else { notes.append(note) }
        }

        func delete(id: String) {
            deleted.append(id)
            notes.removeAll { $0.id == id }
        }
    }

    // MARK: Harness

    static let t0 = Date(timeIntervalSince1970: 1_757_000_000)
    static let t1 = Date(timeIntervalSince1970: 1_757_003_600)

    /// A runner wired to fakes, with its index in a scratch file that is deleted
    /// when `body` returns.
    static func withRunner(folder: FakeFolder, store: FakeStore,
                           _ body: (CloudSync, URL) -> Void) {
        let indexURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("noty-sync-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: indexURL) }
        let wasEnabled = Settings.cloudSyncEnabled
        Settings.cloudSyncEnabled = true
        defer { Settings.cloudSyncEnabled = wasEnabled }
        body(CloudSync(folder: folder, store: store, indexURL: indexURL), indexURL)
    }

    static func note(_ id: String, title: String = "", body: String = "",
                     modified: Date = t0) -> Note {
        var n = Note()
        n.id = id
        n.title = title
        n.body = body
        n.created = modified
        n.modified = modified
        return n
    }

    private static func testAQuietPassReadsNothing(_ check: Check) {
        let folder = FakeFolder()
        let store = FakeStore()
        store.notes = [note("A", title: "Shopping", body: "milk")]

        withRunner(folder: folder, store: store) { sync, indexURL in
            sync.syncNow()
            let firstIndex = try? Data(contentsOf: indexURL)
            folder.reads.removeAll()

            sync.syncNow()
            check(folder.reads.isEmpty,
                  "a pass where no file's date moved must not read any file")

            let secondIndex = try? Data(contentsOf: indexURL)
            check(firstIndex == secondIndex,
                  "a pass that did nothing must not rewrite the index")
        }
    }

    private static func testLosingTheIndexDoesNotRewriteEverything(_ check: Check) {
        let folder = FakeFolder()
        let store = FakeStore()
        store.notes = [note("A", title: "Shopping", body: "milk")]

        withRunner(folder: folder, store: store) { sync, indexURL in
            sync.syncNow()
            check(folder.conflicts.isEmpty, "precondition: a clean first pass")

            // The index file is lost. A fresh runner over the same folder and
            // store must recognise that the two sides already agree.
            try? FileManager.default.removeItem(at: indexURL)
            let second = CloudSync(folder: folder, store: store, indexURL: indexURL)
            second.syncNow()

            check(folder.conflicts.isEmpty,
                  "a lost index must not manufacture a conflict for every note")
            check(store.note(id: "A")?.body == "milk", "the local note must not be reverted")
        }
    }

    // MARK: Tests

    static func run(check: Check) {
        testFirstPassWritesEveryNote(check)
        testAnUnreadableFileNeverDeletesItsNote(check)
        testTwoNotesWithOneTitleGetTwoFiles(check)
        testAPushDoesNotOverwriteAFileTheIndexNeverSaw(check)
        testARenameOnThePhoneDoesNotBreedADuplicate(check)
        testLosingTheIndexDoesNotRewriteEverything(check)
        testAQuietPassReadsNothing(check)
        testACopiedFileLandsOnTheDeckAsASecondNote(check)
    }

    private static func testARenameOnThePhoneDoesNotBreedADuplicate(_ check: Check) {
        let folder = FakeFolder()
        let store = FakeStore()
        store.notes = [note("A", title: "Todo", body: "one")]

        withRunner(folder: folder, store: store) { sync, _ in
            sync.syncNow()
            check(folder.files["Todo.md"] != nil, "precondition: the note was written")

            // Renamed in the Files app. A rename does not change the contents,
            // so the mtime the app recorded still stands.
            let text = folder.files.removeValue(forKey: "Todo.md")!
            let date = folder.dates.removeValue(forKey: "Todo.md")!
            folder.files["Groceries.md"] = text
            folder.dates["Groceries.md"] = date

            // Now edit the note locally, which forces a push.
            store.notes[0].body = "two"
            store.notes[0].modified = t1
            sync.syncNow()

            check(folder.files["Todo.md"] == nil,
                  "the push must not resurrect the name the phone renamed away from")
            check(folder.files.count == 1,
                  "one note must never end up as two files sharing one noty-id")
            check(folder.files["Groceries.md"]?.contains("two") == true,
                  "the edit must land in the file the phone actually has")
        }
    }

    private static func testTwoNotesWithOneTitleGetTwoFiles(_ check: Check) {
        let folder = FakeFolder()
        let store = FakeStore()
        store.notes = [note("A", title: "Ideas", body: "first"),
                       note("B", title: "Ideas", body: "second")]

        withRunner(folder: folder, store: store) { sync, _ in
            sync.syncNow()
            check(folder.files.count == 2,
                  "two notes must never share one file — the second would overwrite the first")
            let bodies = Set(folder.files.values.map { $0.contains("first") })
            check(bodies == [true, false], "both notes' contents must survive")
        }
    }

    /// A name the folder holds but the index has never seen — a file created on
    /// another device while this Mac was offline. Allocating against the index
    /// alone let a push overwrite it.
    private static func testAPushDoesNotOverwriteAFileTheIndexNeverSaw(_ check: Check) {
        let folder = FakeFolder()
        let store = FakeStore()
        store.notes = [note("A", title: "Ideas", body: "mine")]
        var phone = Note()
        phone.id = "PHONE"
        phone.body = "theirs"
        phone.created = t0
        phone.modified = t0
        folder.place(phone, named: "Ideas.md", at: t0)

        withRunner(folder: folder, store: store) { sync, _ in
            sync.syncNow()
            check(folder.files.values.contains(where: { $0.contains("theirs") }),
                  "a file the index never saw must not be overwritten")
            check(folder.files.values.contains(where: { $0.contains("mine") }),
                  "the local note must still be written out")
        }
    }

    /// The defect that motivated this plan: with "Optimize Mac Storage" on,
    /// iCloud evicts file contents. A pass that cannot read a file must say
    /// nothing about it at all.
    private static func testAnUnreadableFileNeverDeletesItsNote(_ check: Check) {
        let folder = FakeFolder()
        let store = FakeStore()
        store.notes = [note("A", title: "Shopping", body: "milk")]

        withRunner(folder: folder, store: store) { sync, _ in
            sync.syncNow()                              // first pass writes Shopping.md
            check(folder.files["Shopping.md"] != nil, "precondition: the file was written")

            folder.unresolved.insert("Shopping.md")     // iCloud evicts the contents
            sync.syncNow()

            check(store.deleted.isEmpty,
                  "an unreadable file must never delete the note behind it")
            check(store.note(id: "A") != nil, "the note must still be in the store")
            check(!folder.removed.contains("Shopping.md"),
                  "an unreadable file must not be removed either")
        }
    }

    private static func testFirstPassWritesEveryNote(_ check: Check) {
        let folder = FakeFolder()
        let store = FakeStore()
        store.notes = [note("A", title: "Shopping", body: "milk")]

        withRunner(folder: folder, store: store) { sync, _ in
            check(sync.syncNow(), "a pass with an available folder must run")
            check(folder.files["Shopping.md"] != nil,
                  "the note must be written out under its title")
            check(folder.files["Shopping.md"]?.contains("noty-id: A") == true,
                  "the written document must carry the note's identity")
            check(store.deleted.isEmpty, "a first pass must never delete anything")
        }
    }

    private static func testACopiedFileLandsOnTheDeckAsASecondNote(_ check: Check) {
        let folder = FakeFolder()
        let store = FakeStore()
        store.notes = [note("A", title: "Site", body: "one")]

        withRunner(folder: folder, store: store) { sync, _ in
            sync.syncNow()
            check(folder.files["Site.md"] != nil, "precondition: the note was written")

            // Duplicated in the Files app: the header travels with the body, and
            // a Finder copy keeps the modification date too.
            folder.files["Site 2.md"] = folder.files["Site.md"]
            folder.dates["Site 2.md"] = folder.dates["Site.md"]
            sync.syncNow()

            check(store.notes.count == 2, "the copy must land on the deck as a second note")
            check(Set(store.notes.map(\.id)).count == 2,
                  "the two notes must not share an identity")
            check(folder.files["Site 2.md"]?.contains("noty-id: A") == false,
                  "the copy's file must be rewritten with its own identity")
            check(folder.files["Site.md"]?.contains("noty-id: A") == true,
                  "the original must keep the identity the index knows")
            check(store.deleted.isEmpty, "nothing may be deleted to resolve a duplicate")
        }
    }

}
