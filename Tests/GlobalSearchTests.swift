import AppKit
import Carbon.HIToolbox

enum GlobalSearchTests {
    static func run(check: (Bool, String) -> Void) {
        let recent = Note(id: "recent", title: "周会安排", body: "会议时间是周五", modified: Date(timeIntervalSince1970: 30))
        let archived = Note(id: "archive", title: "产品计划", body: "<span data-noty-style=\"b,z24\">搜索中文🙂</span>",
                            modified: Date(timeIntervalSince1970: 20), archived: true, project: "Noty", tags: ["设计"])
        let trashed = Note(id: "trash", body: "搜索中文🙂", deletedAt: Date())
        let notes = [archived, trashed, recent]
        var model = GlobalSearchResults()
        model.update(query: "", notes: notes)
        check(model.notes.map(\.id) == [recent.id, archived.id], "global search must show recent active and archived notes, excluding trash")
        check(model.selected?.id == recent.id, "opening search must select the first result")
        model.move(1)
        check(model.selected?.id == archived.id, "Down must select the next result")
        model.move(1)
        check(model.selected?.id == archived.id, "Down at the end must stay in bounds")
        model.move(-20)
        check(model.selected?.id == recent.id, "Up at the beginning must stay in bounds")
        model.update(query: "周会", notes: notes)
        check(model.selected?.id == recent.id, "global search must match note titles")
        model.update(query: "  noty  设计 中文🙂  ", notes: notes)
        check(model.notes.map(\.id) == [archived.id], "global search must AND words across project, tags and styled body, including Chinese and emoji")
        model.update(query: "data-noty-style", notes: notes)
        check(model.notes.isEmpty && model.selected == nil, "internal style markers must not become search results")
        model.move(1)
        check(model.selected == nil, "navigation with no matches must be safe")
        model.update(query: "  \n ", notes: notes)
        check(model.notes.count == 2, "whitespace must behave as an empty search")
        model.move(1)
        var changed = archived
        changed.modified = Date(timeIntervalSince1970: 40)
        model.update(query: "  \n ", notes: [recent, changed])
        check(model.selected?.id == archived.id && model.selectedIndex == 0,
              "live updates that reorder results must retain the selected identity")
        changed.deletedAt = Date()
        model.update(query: "  \n ", notes: [recent, changed])
        check(model.selected?.id == recent.id, "trashing the selection must remove it and choose a valid result")
        model.update(query: "no matches", notes: notes)
        check(model.selected == nil, "a new unmatched query must clear the previous selection")

        let long = Note(body: String(repeating: "很长的内容 ", count: 100)
                        + "<span data-noty-style=\"b\">关键字🙂</span> 后续内容 ![image](noty-img://abc)")
        let preview = GlobalSearchResults.snippet(for: long, query: "关键字")
        check(preview.contains("关键字🙂") && preview.hasPrefix("…"), "long result previews must include the matching passage")
        check(!preview.contains("<span") && !preview.contains("noty-img"), "result previews must hide internal formatting and image syntax")
        check(GlobalSearchResults.snippet(for: Note(), query: "").isEmpty, "empty bodies must have a safe empty preview")
        testHotKeyDispatch(check: check)
    }

    private static func testHotKeyDispatch(check: (Bool, String) -> Void) {
        _ = NSApplication.shared
        let saved = (Settings.scNewNote, Settings.scAllNotes, Settings.scArchive, Settings.scCapture, Settings.scGlobalSearch)
        defer {
            HotKeys.shared.unregisterAll()
            Settings.scNewNote = saved.0; Settings.scAllNotes = saved.1
            Settings.scArchive = saved.2; Settings.scCapture = saved.3; Settings.scGlobalSearch = saved.4
        }
        // Tests use an isolated defaults suite and an unused combination so a
        // running installed copy of Noty keeps all its usual global shortcuts.
        let shortcut = Shortcut(keyCode: UInt32(kVK_F19),
                                modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))
        Settings.scNewNote = .none; Settings.scAllNotes = .none
        Settings.scArchive = .none; Settings.scCapture = .none
        Settings.scGlobalSearch = shortcut
        var opened = 0
        HotKeys.shared.register(newNote: {}, allNotes: {}, archive: {}, capture: {}, search: { opened += 1 })
        check(!HotKeys.shared.unavailableShortcuts.contains(shortcut), "search hotkey must register with the macOS global hotkey service")

        // Deliver a Carbon hotkey notification to this test process only. No
        // keyboard events or actions are sent to the user's other applications.
        var event: EventRef?
        let created = CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                                  GetCurrentEventTime(), EventAttributes(kEventAttributeUserEvent), &event)
        if created == noErr, let event {
            defer { ReleaseEvent(event) }
            var identity = EventHotKeyID(signature: 0x4E4F5459, id: 5)
            SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              MemoryLayout<EventHotKeyID>.size, &identity)
            SendEventToEventTarget(event, GetApplicationEventTarget())
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.04))
            check(opened == 1, "the global search hotkey notification must dispatch its open action exactly once")
        } else { check(false, "test hotkey notification must be created") }

        let item = NSMenuItem()
        Shortcut(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(optionKey | cmdKey)).apply(to: item)
        check(!item.keyEquivalent.isEmpty && item.keyEquivalentModifierMask == [.option, .command],
              "search menu shortcut must match the global modifiers")
        Shortcut.none.apply(to: item)
        check(item.keyEquivalent.isEmpty, "clearing the search shortcut must also disable its menu shortcut")
    }
}
