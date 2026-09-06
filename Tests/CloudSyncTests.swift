import Foundation

/// Checks for the iCloud Drive sync path: task round-tripping, the on-disk
/// document format, folder naming, and the sync decision table.
enum CloudSyncTests {
    typealias Check = (Bool, String) -> Void

    static func run(check: Check) {
        testRenderWritesEveryField(check)
        testRenderOmitsDerivedTitle(check)
        testParseRoundTrip(check)
        testParseAdoptsFileWithoutHeader(check)
        testParseIgnoresUnknownKeysAndKeepsColonsInTitle(check)
        testParseSurvivesABodyThatStartsWithAFence(check)
        testParseFallsBackToTheFileName(check)
        testAHorizontalRuleIsNotFrontMatter(check)
        testAKeyValueBlockWithNoNotyKeysIsNotFrontMatter(check)
        testFileNameSlugAndCollisions(check)
        testAParenthesisedTitleIsNotMistakenForAConflictCopy(check)
        testConflictCopiesLiveInASubdirectory(check)
        testCoordinatedFileIO(check)
        testPlaceholdersAreSeenAsUnresolved(check)
        testIndexPersistence(check)
        testPlanPushesANoteNeverSynced(check)
        testPlanIsQuietWhenNothingChanged(check)
        testPlanPushesALocalEdit(check)
        testPlanPullsARemoteEdit(check)
        testPlanAdoptsAFileWithNoIdentity(check)
        testPlanDeletesBothWays(check)
        testPlanDetectsConflictsAndPicksTheNewer(check)
        testPlanSaysNothingAboutAnUnresolvedFile(check)
        testACopiedDocumentBecomesItsOwnNote(check)
        testTheIndexedDocumentIsTheOneThatKeepsTheIdentity(check)
        testAMissingIndexEntryIsNotAConflictWhenBothSidesAgree(check)
        testConflictDocumentHasNoIdentity(check)
    }

    // MARK: Rendering

    /// A fixed, whole-second date so ISO 8601's lack of sub-second precision
    /// cannot make a round-trip test flap.
    private static let t0 = Date(timeIntervalSince1970: 1_757_000_000)
    private static let t1 = Date(timeIntervalSince1970: 1_757_003_600)

    private static func testRenderWritesEveryField(_ check: Check) {
        var note = Note()
        note.id = "FIXED-ID"
        note.title = "Shopping"
        note.body = "\(Tasks.openPrefix)milk\n\(Tasks.donePrefix)eggs"
        note.color = 3
        note.created = t0
        note.modified = t1
        note.archived = true
        note.pinned = true
        note.order = -2.5
        note.textDirection = .rightToLeft

        let expected = """
        ---
        noty-id: FIXED-ID
        color: 3
        created: \(NoteDocument.stamp.string(from: t0))
        modified: \(NoteDocument.stamp.string(from: t1))
        archived: true
        pinned: true
        order: -2.5
        direction: rightToLeft
        title: Shopping
        ---

        - [ ] milk
        - [x] eggs
        """
        check(NoteDocument.render(note) == expected,
              "render must write the full header and markdown-form tasks")
    }

    private static func testRenderOmitsDerivedTitle(_ check: Check) {
        var note = Note()
        note.title = ""
        note.body = "just a body"
        check(!NoteDocument.render(note).contains("\n\(NoteDocument.Key.title):"),
              "a derived title is not a choice anyone made and must not be written out")
    }

    // MARK: Parsing

    private static func testParseRoundTrip(_ check: Check) {
        var note = Note()
        note.id = "ROUND-TRIP"
        note.title = "Custom: with a colon"
        note.body = "\(Tasks.openPrefix)one\nplain\n\(Tasks.donePrefix)two"
        note.color = 5
        note.created = t0
        note.modified = t1
        note.archived = true
        note.pinned = true
        note.order = -4
        note.textDirection = .leftToRight

        let parsed = NoteDocument.parse(NoteDocument.render(note), fallbackTitle: "")
        check(parsed.hasIdentity, "a rendered document must carry its identity")
        check(parsed.note == note, "render then parse must return the identical note")
    }

    private static func testParseAdoptsFileWithoutHeader(_ check: Check) {
        let parsed = NoteDocument.parse("# Groceries\n\n- [ ] milk",
                                        fallbackTitle: "Groceries")
        check(!parsed.hasIdentity, "a plain markdown file has no identity yet")
        check(parsed.note.body == "# Groceries\n\n\(Tasks.openPrefix)milk",
              "a headerless file is all body, with its tasks converted")
        check(!parsed.note.hasCustomTitle,
              "a title derivable from the body must stay derived")
    }

    private static func testParseIgnoresUnknownKeysAndKeepsColonsInTitle(_ check: Check) {
        let text = """
        ---
        noty-id: KEEP
        title: Ratio: 3:1
        something-else: ignored
        color: 2
        ---

        body
        """
        let parsed = NoteDocument.parse(text, fallbackTitle: "")
        check(parsed.note.title == "Ratio: 3:1",
              "a value must be split on the first colon only")
        check(parsed.note.color == 2, "known keys after an unknown one must still parse")
        check(parsed.note.body == "body", "unknown keys must not leak into the body")
    }

    private static func testParseSurvivesABodyThatStartsWithAFence(_ check: Check) {
        var note = Note()
        note.id = "FENCED"
        note.body = "---\nan em dash rule opens this note\n---"
        note.created = t0
        note.modified = t0
        let parsed = NoteDocument.parse(NoteDocument.render(note), fallbackTitle: "")
        check(parsed.note.body == note.body,
              "only the first closing fence ends the header")
    }

    private static func testParseFallsBackToTheFileName(_ check: Check) {
        let parsed = NoteDocument.parse("", fallbackTitle: "Untitled from phone")
        check(parsed.note.title == "Untitled from phone",
              "an empty file takes its title from its filename")
    }

    private static func testAHorizontalRuleIsNotFrontMatter(_ check: Check) {
        let text = """
        ---
        Intro line
        ---
        Body line
        """
        let parsed = NoteDocument.parse(text, fallbackTitle: "From phone")
        check(!parsed.hasIdentity, "there is no identity in a note that opens with a rule")
        check(parsed.note.body == text,
              "a note that opens with a horizontal rule must survive intact")
    }

    private static func testAKeyValueBlockWithNoNotyKeysIsNotFrontMatter(_ check: Check) {
        let text = """
        ---
        Author: someone
        Mood: bright
        ---
        Body line
        """
        let parsed = NoteDocument.parse(text, fallbackTitle: "From phone")
        check(parsed.note.body == text,
              "somebody else's front matter is content, not something to swallow")
    }

    // MARK: Folder

    private static func testFileNameSlugAndCollisions(_ check: Check) {
        var note = Note()
        note.title = "Trip / notes: 2026"
        let first = CloudFolder.fileName(for: note, avoiding: [])
        check(first == "Trip - notes- 2026.md",
              "path-hostile characters must be replaced, not dropped")

        note.title = "https://example.com/post?id=1"
        check(CloudFolder.fileName(for: note, avoiding: []) == "https-example.com-post-id=1.md",
              "a url title must not collapse into a run of dashes")
        note.title = "//example.com"
        check(CloudFolder.fileName(for: note, avoiding: []) == "example.com.md",
              "a title of only separators must not leave leading dashes")
        note.title = "Trip / notes: 2026"

        let second = CloudFolder.fileName(for: note, avoiding: [first.lowercased()])
        check(second == "Trip - notes- 2026-2.md", "a taken name must be suffixed")

        var blank = Note()
        blank.id = "ABCDEFGH-1234"
        blank.title = ""
        blank.body = ""
        check(CloudFolder.fileName(for: blank, avoiding: []) == "note-ABCDEFGH.md",
              "a note with no title falls back to its id")

        var dotted = Note()
        dotted.id = "ZYXWVUTS-9999"
        dotted.title = ".hidden"
        check(CloudFolder.fileName(for: dotted, avoiding: []) == "note-ZYXWVUTS.md",
              "a leading dot would hide the file from the Files app")
    }

    private static func testAParenthesisedTitleIsNotMistakenForAConflictCopy(_ check: Check) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("noty-conflict-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var note = Note()
        note.title = "Refactor (conflict resolution)"
        let name = CloudFolder.fileName(for: note, avoiding: [])
        check(name == "Refactor (conflict resolution).md",
              "a title with parentheses keeps them")

        try? "x".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        check(CloudFolder.scan(in: dir).documents[name] != nil,
              "a note whose title merely reads like a conflict must stay visible")
    }

    private static func testConflictCopiesLiveInASubdirectory(_ check: Check) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("noty-conflict2-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        check(CloudFolder.writeConflict("loser", named: "Shopping.md", in: dir),
              "a conflict copy must be written")
        let sidecars = (try? FileManager.default.contentsOfDirectory(
            atPath: dir.appendingPathComponent(CloudFolder.conflictsFolderName).path)) ?? []
        check(sidecars.count == 1, "the copy lands in the Conflicts subdirectory")
        check(sidecars[0].hasPrefix("Shopping (conflict "),
              "the copy names the note it came from")
        check(CloudFolder.scan(in: dir).allNames.isEmpty,
              "a conflict copy must never be enumerated as a note document")
    }

    private static func testPlaceholdersAreSeenAsUnresolved(_ check: Check) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("noty-placeholder-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try? "hello".write(to: dir.appendingPathComponent("Present.md"),
                           atomically: true, encoding: .utf8)
        // What iCloud leaves behind when it evicts "Evicted.md".
        try? "".write(to: dir.appendingPathComponent(".Evicted.md.icloud"),
                      atomically: true, encoding: .utf8)
        try? "".write(to: dir.appendingPathComponent(".DS_Store"),
                      atomically: true, encoding: .utf8)

        let scan = CloudFolder.scan(in: dir)
        check(scan.documents["Present.md"] != nil, "a downloaded document is listed")
        check(scan.unresolved.contains("Evicted.md"),
              "an evicted document must be reported under its real name, not as missing")
        check(!scan.allNames.contains(".DS_Store"),
              "hidden files that are not placeholders must be ignored")
        check(scan.allNames == ["Present.md", "Evicted.md"],
              "the folder holds exactly these two documents")
    }

    private static func testCoordinatedFileIO(_ check: Check) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("noty-cloud-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("Shopping.md")
        check(CloudFolder.write("hello", to: file), "write must report success")
        check(CloudFolder.read(file) == "hello", "read must return what write stored")
        check(CloudFolder.modificationDate(of: file) != nil, "a written file has a date")

        let conflictName = CloudFolder.conflictName(for: "Shopping.md", at: t0)
        let conflict = dir.appendingPathComponent(conflictName)
        check(CloudFolder.write("loser", to: conflict), "conflict files are written the same way")
        try? "not markdown".write(to: dir.appendingPathComponent("cover.png"),
                                  atomically: true, encoding: .utf8)

        let found = CloudFolder.documentURLs(in: dir).map(\.lastPathComponent)
        check(found == [conflictName, "Shopping.md"],
              "listing must keep markdown files and skip anything that is not .md")

        check(CloudFolder.remove(file), "remove must report success")
        check(CloudFolder.read(file) == nil, "a removed file cannot be read back")
    }

    // MARK: Index

    private static func testIndexPersistence(_ check: Check) {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("noty-index-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        var index = CloudSyncIndex()
        index.record(noteID: "A", fileName: "Shopping.md", noteModified: t0, fileModified: t1)
        index.save(to: file)

        let loaded = CloudSyncIndex.load(from: file)
        check(loaded.entries["A"]?.fileName == "Shopping.md", "an entry must survive a save/load")
        check(loaded.entries["A"]?.syncedModified == t0, "the note date must survive")
        check(loaded.entries["A"]?.fileModified == t1, "the file date must survive")
        check(loaded.id(forFileName: "Shopping.md") == "A", "a filename must resolve to its id")
        check(loaded.id(forFileName: "Missing.md") == nil, "an unknown filename resolves to nothing")

        var trimmed = loaded
        trimmed.forget(noteID: "A")
        check(trimmed.entries.isEmpty, "forget must drop the entry")

        let absent = CloudSyncIndex.load(
            from: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("noty-index-does-not-exist.json"))
        check(absent.entries.isEmpty, "a missing index file loads as an empty index")
    }

    // MARK: Planning

    private static func testACopiedDocumentBecomesItsOwnNote(_ check: Check) {
        let actions = SyncPlan.actions(
            notes: [note("A", modified: t0)],
            // The copy carries the original's header, mtime and all.
            remote: [remote("Site.md", id: "A", declared: t0, file: t0),
                     remote("Site copy.md", id: "A", declared: t0, file: t0)],
            unresolved: [],
            index: synced("A", "Site.md", noteDate: t0, fileDate: t0))
        check(actions == [.adopt(fileName: "Site copy.md")],
              "the copy must become a note of its own, not shadow the original")
    }

    private static func testTheIndexedDocumentIsTheOneThatKeepsTheIdentity(_ check: Check) {
        // The copy sorts last and is newer, but the index already knows which
        // document this note lives in. That one keeps the identity.
        let actions = SyncPlan.actions(
            notes: [note("A", modified: t0)],
            remote: [remote("Site.md", id: "A", declared: t0, file: t0),
                     remote("zzz copy.md", id: "A", declared: t0, file: t1)],
            unresolved: [],
            index: synced("A", "Site.md", noteDate: t0, fileDate: t0))
        check(actions == [.adopt(fileName: "zzz copy.md")],
              "the document the index names keeps the identity, whatever the copy's date")
    }

    private static func note(_ id: String, modified: Date) -> Note {
        var n = Note()
        n.id = id
        n.modified = modified
        return n
    }

    private static func remote(_ name: String, id: String?,
                               declared: Date, file: Date) -> SyncPlan.RemoteFile {
        SyncPlan.RemoteFile(fileName: name, noteID: id,
                            declaredModified: declared, fileModified: file)
    }

    private static func synced(_ id: String, _ name: String,
                               noteDate: Date, fileDate: Date) -> CloudSyncIndex {
        var index = CloudSyncIndex()
        index.record(noteID: id, fileName: name, noteModified: noteDate, fileModified: fileDate)
        return index
    }

    private static func testPlanPushesANoteNeverSynced(_ check: Check) {
        let actions = SyncPlan.actions(notes: [note("A", modified: t0)],
                                       remote: [], unresolved: [], index: CloudSyncIndex())
        check(actions == [.push(noteID: "A", existingFileName: nil)], "an unsynced note with no file must be pushed")
    }

    private static func testPlanIsQuietWhenNothingChanged(_ check: Check) {
        let actions = SyncPlan.actions(
            notes: [note("A", modified: t0)],
            remote: [remote("A.md", id: "A", declared: t0, file: t0)],
            unresolved: [], index: synced("A", "A.md", noteDate: t0, fileDate: t0))
        check(actions.isEmpty, "an unchanged pair must produce no work")
    }

    private static func testPlanPushesALocalEdit(_ check: Check) {
        let actions = SyncPlan.actions(
            notes: [note("A", modified: t1)],
            remote: [remote("A.md", id: "A", declared: t0, file: t0)],
            unresolved: [], index: synced("A", "A.md", noteDate: t0, fileDate: t0))
        check(actions == [.push(noteID: "A", existingFileName: "A.md")], "a newer note must be pushed")
    }

    private static func testPlanPullsARemoteEdit(_ check: Check) {
        // The header still says t0 — an editor on the phone does not update it.
        // Only the file's own date moved.
        let actions = SyncPlan.actions(
            notes: [note("A", modified: t0)],
            remote: [remote("A.md", id: "A", declared: t0, file: t1)],
            unresolved: [], index: synced("A", "A.md", noteDate: t0, fileDate: t0))
        check(actions == [.pull(fileName: "A.md")],
              "a file touched by a foreign editor must be pulled")
    }

    private static func testPlanAdoptsAFileWithNoIdentity(_ check: Check) {
        let actions = SyncPlan.actions(
            notes: [], remote: [remote("From phone.md", id: nil, declared: .distantPast, file: t1)],
            unresolved: [], index: CloudSyncIndex())
        check(actions == [.adopt(fileName: "From phone.md")],
              "a file with no noty-id is a new note from another device")
    }

    private static func testPlanDeletesBothWays(_ check: Check) {
        let goneRemotely = SyncPlan.actions(
            notes: [note("A", modified: t0)], remote: [],
            unresolved: [], index: synced("A", "A.md", noteDate: t0, fileDate: t0))
        check(goneRemotely == [.deleteLocal(noteID: "A")],
              "a synced note whose file vanished was deleted elsewhere")

        let goneLocally = SyncPlan.actions(
            notes: [], remote: [remote("A.md", id: "A", declared: t0, file: t0)],
            unresolved: [], index: synced("A", "A.md", noteDate: t0, fileDate: t0))
        check(goneLocally == [.deleteRemote(fileName: "A.md")],
              "a file whose note was deleted here must go")

        let neverSeen = SyncPlan.actions(
            notes: [], remote: [remote("A.md", id: "A", declared: t0, file: t0)],
            unresolved: [], index: CloudSyncIndex())
        check(neverSeen == [.pull(fileName: "A.md")],
              "an identified file this Mac has never synced is a note to pull, not a deletion")
    }

    private static func testPlanDetectsConflictsAndPicksTheNewer(_ check: Check) {
        let localNewer = SyncPlan.actions(
            notes: [note("A", modified: t1)],
            remote: [remote("A.md", id: "A", declared: t0, file: t0.addingTimeInterval(60))],
            unresolved: [], index: synced("A", "A.md", noteDate: t0, fileDate: t0))
        check(localNewer == [.conflict(noteID: "A", fileName: "A.md", localWins: true)],
              "both sides changed and the note is newer")

        let remoteNewer = SyncPlan.actions(
            notes: [note("A", modified: t0.addingTimeInterval(60))],
            remote: [remote("A.md", id: "A", declared: t0, file: t1)],
            unresolved: [], index: synced("A", "A.md", noteDate: t0, fileDate: t0))
        check(remoteNewer == [.conflict(noteID: "A", fileName: "A.md", localWins: false)],
              "both sides changed and the file is newer")
    }

    private static func testAMissingIndexEntryIsNotAConflictWhenBothSidesAgree(_ check: Check) {
        let actions = SyncPlan.actions(
            notes: [note("A", modified: t0)],
            // The file declares the same modified the note has; iCloud set the
            // file's own mtime later, which is normal and means nothing.
            remote: [remote("A.md", id: "A", declared: t0, file: t1)],
            unresolved: [],
            index: CloudSyncIndex())          // the index was lost
        check(actions == [.reindex(noteID: "A", fileName: "A.md")],
              "an agreeing pair with no index entry must be recorded, not fought over")
    }

    private static func testPlanSaysNothingAboutAnUnresolvedFile(_ check: Check) {
        let actions = SyncPlan.actions(
            notes: [note("A", modified: t0)],
            remote: [],                              // could not be read, so not here
            unresolved: ["A.md"],
            index: synced("A", "A.md", noteDate: t0, fileDate: t0))
        check(actions.isEmpty,
              "a note whose file exists but could not be read must produce no action")
    }

    private static func testConflictDocumentHasNoIdentity(_ check: Check) {
        var note = Note()
        note.id = "LOSER"
        note.title = "Shopping"
        note.body = "\(Tasks.openPrefix)milk"

        let text = CloudSync.conflictDocument(for: note)
        check(!text.contains(NoteDocument.Key.id),
              "a conflict copy must carry no identity, or it would sync back as a note")
        check(text.contains("# Shopping"), "a conflict copy names the note it came from")
        check(text.contains("- [ ] milk"), "a conflict copy keeps the content it saved")
    }
}
