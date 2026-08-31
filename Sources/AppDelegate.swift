import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var deckManager: DeckManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMainMenu()

        deckManager = DeckManager()
        UndoToast.shared.start()

        HotKeys.shared.register(
            newNote: { [weak self] in self?.newNote() },
            allNotes: { [weak self] in self?.openAllNotes() },
            archive:  { [weak self] in self?.openArchive() }
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeys.shared.unregisterAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Actions

    @objc func newNote() {
        let note = NoteStore.shared.create()
        deckManager.focused?.expand(note.id)
    }

    @objc func openAllNotes() { LibraryWindow.shared.show(mode: .all) }
    @objc func openArchive() { LibraryWindow.shared.show(mode: .archive) }

    @objc func toggleOverFullScreen() {
        Settings.showOverFullScreen.toggle()
        deckManager.refreshAll()
    }

    @objc func setDeckStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = DeckStyle(rawValue: raw) else { return }
        Settings.deckStyle = style
        deckManager.refreshAll()
    }

    @objc func setFontSize(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? Double else { return }
        Settings.noteFontSize = size
        deckManager.refreshAll()
    }

    /// ⌃+ / ⌃- while a note is open.
    func stepFontSize(by delta: Double) {
        Settings.noteFontSize += delta
        deckManager.refreshAll()
    }

    @objc func biggerText()  { stepFontSize(by: 1.5) }
    @objc func smallerText() { stepFontSize(by: -1.5) }

    @objc func setNoteFont(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Settings.noteFontName = name
        deckManager.refreshAll()
    }

    @objc func toggleDeckEdge() {
        Settings.deckOnLeftEdge.toggle()
        deckManager.refreshAll()
    }

    @objc func toggleLaunchAtLogin() {
        Settings.launchAtLogin.toggle()
    }

    @objc func exportMarkdown()  { Transfer.export(.markdown,  notes: NoteStore.shared.notes) }
    @objc func exportPlainText() { Transfer.export(.plainText, notes: NoteStore.shared.notes) }
    @objc func exportSingleFile(){ Transfer.export(.singleFile, notes: NoteStore.shared.notes) }
    @objc func exportStickies()  { Transfer.export(.stickies,  notes: NoteStore.shared.notes) }
    @objc func importStickies()  { Transfer.importFiles() }

    @objc func checkForUpdates() { Updater.shared.checkForUpdates() }

    @objc func toggleAutoUpdates() {
        Updater.shared.automaticallyChecks.toggle()
    }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func showAbout() {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "Noty"
        a.informativeText = """
        Стикеры заметок прикреплены к краю экрана.

        ⌥⌘N  новая заметка      ⌥⌘A  все заметки      ⌥⌘L  архив
        В заметке — Esc закрывает, ⌘F ищет, ⌘. меняет цвет, ⌘⌫ удаляет.

        Заметки хранятся локально в базе SQLite, а текст зашифрован AES-GCM. \
        Заметки не покидают этот Mac: единственный сетевой запрос — проверка \
        обновлений, которую можно отключить.
        """
        a.runModal()
    }

    // MARK: Main menu
    //
    // An accessory app draws no menu bar, but NSApp.mainMenu is still what
    // dispatches ⌘C/⌘V/⌘Z inside the note editor — without it, text editing
    // loses every standard shortcut.

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "О Noty", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(withTitle: "Проверить обновления…", action: #selector(checkForUpdates), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Новая заметка", action: #selector(newNote), keyEquivalent: "n")
        appMenu.addItem(withTitle: "Все заметки", action: #selector(openAllNotes), keyEquivalent: "a")
        appMenu.addItem(withTitle: "Архив", action: #selector(openArchive), keyEquivalent: "l")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Импортировать…", action: #selector(importStickies), keyEquivalent: "i")
        appMenu.addItem(.separator())
        let bigger = appMenu.addItem(withTitle: "Увеличить текст", action: #selector(biggerText), keyEquivalent: "+")
        bigger.keyEquivalentModifierMask = [.control]
        let smaller = appMenu.addItem(withTitle: "Уменьшить текст", action: #selector(smallerText), keyEquivalent: "-")
        smaller.keyEquivalentModifierMask = [.control]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Скрыть Noty", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Выйти из Noty", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // The three global shortcuts already carry ⌥; mirror that here so the menu
        // items do not shadow ⌘N / ⌘A / ⌘L inside text fields.
        for title in ["Новая заметка", "Все заметки", "Архив"] {
            appMenu.item(withTitle: title)?.keyEquivalentModifierMask = [.command, .option]
        }
        for item in appMenu.items where item.action != nil
            && item.action != #selector(NSApplication.hide(_:))
            && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Повторить", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}
