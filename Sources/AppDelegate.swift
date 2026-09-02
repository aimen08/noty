import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var deckManager: DeckManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMainMenu()

        deckManager = DeckManager()
        restoreAfterLanguageRelaunch()
        UndoToast.shared.start()

        HotKeys.shared.register(
            newNote: { [weak self] in self?.newNote() },
            allNotes: { [weak self] in self?.openAllNotes() },
            archive:  { [weak self] in self?.openArchive() },
            capture:  { QuickCapture.shared.toggle() }
        )

        // Sparkle only schedules its background checks once the controller
        // exists. Until now nothing touched it before the pill's context menu
        // was opened, so a user who never right-clicked was never offered an
        // update however long the app ran.
        _ = Updater.shared
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
    @objc func quickCapture() { QuickCapture.shared.toggle() }

    /// noty:// — the whole automation surface. The text only ever becomes note
    /// content, never anything executed, so there is nothing here to harden
    /// beyond ignoring what we do not recognise.
    ///   noty://new?text=…   create a note (no text → open quick capture)
    ///   noty://capture      open the quick capture box
    ///   noty://all          the All Notes window
    ///   noty://settings     the Settings window
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "noty" {
            let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "text" }?.value ?? ""
            switch url.host {
            case "new" where !text.isEmpty:
                _ = NoteStore.shared.create(body: text)
            case "new", "capture":
                QuickCapture.shared.show()
            case "all":      openAllNotes()
            case "settings": openSettings()
            default: break
            }
        }
    }
    @objc func openSettings() { SettingsWindow.shared.show() }

    /// Re-read preferences into every deck. Settings calls this on each change.
    func refreshDecks() { deckManager.refreshAll() }
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

    @objc func toggleDeckAlwaysShown() {
        Settings.deckAlwaysShown.toggle()
        deckManager.refreshAll()
    }

    @objc func setDeckScale(_ sender: NSMenuItem) {
        guard let scale = sender.representedObject as? Double else { return }
        Settings.deckScale = scale
        deckManager.refreshAll()
    }

    @objc func toggleDeckEdge() {
        Settings.deckOnLeftEdge.toggle()
        deckManager.refreshAll()
    }

    @objc func setDisplayTarget(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? String else { return }
        Settings.displayTarget = target
        SettingsWindow.shared.syncPreferences()
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

    /// Bundle localization is fixed for the lifetime of a process. Launch the
    /// replacement first, then terminate only after Launch Services confirms it.
    /// On failure the preference is rolled back and the picker re-synced, so the
    /// window does not sit there claiming a language the running UI never uses.
    func relaunchForLanguageChange(previous: AppLanguage) {
        guard !isRelaunching else { return }
        isRelaunching = true

        // Hand the new instance everything worth putting back: the expanded
        // note (one per screen is impossible, only one deck is ever expanded)
        // and, most importantly, the settings window the user is standing in.
        let expanded = deckManager.decks.values.first { $0.model.state.expandedID != nil }
        let resume = ReloadResume(
            noteID: expanded?.model.state.expandedID,
            displayID: expanded?.displayID,
            settingsOpen: SettingsWindow.shared.isOpen)
        if resume.open { ReloadResume.save(resume) }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    NSLog("Noty: language-change relaunch failed — \(error.localizedDescription)")
                    ReloadResume.clear()
                    Settings.appLanguage = previous
                    SettingsWindow.shared.syncPreferences()
                    self.isRelaunching = false
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// A language-change relaunch through the state the old process handed
    /// over: reopen the same note on the same display, and the settings window.
    private func restoreAfterLanguageRelaunch() {
        guard let resume = ReloadResume.loadAndClear(), resume.open else { return }
        if let id = resume.noteID, NoteStore.shared.note(id: id) != nil {
            // Let the freshly launched deck settle into its resting pose before
            // the note animates in, so it does not fight the restore.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                let deck = self?.deckManager.decks[resume.displayID ?? 0] ?? self?.deckManager.focused
                deck?.expand(id)
            }
        }
        if resume.settingsOpen { openSettings() }
    }

    private var isRelaunching = false

    @objc func showAbout() {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "Noty"
        a.informativeText = L10n.text("about.body")
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
        appMenu.addItem(withTitle: L10n.text("menu.about"), action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(withTitle: L10n.text("menu.check_for_updates"), action: #selector(checkForUpdates), keyEquivalent: "")
        appMenu.addItem(.separator())
        let newNoteItem = appMenu.addItem(withTitle: L10n.text("menu.new_note"), action: #selector(newNote), keyEquivalent: "n")
        let allNotesItem = appMenu.addItem(withTitle: L10n.text("menu.all_notes"), action: #selector(openAllNotes), keyEquivalent: "a")
        let archiveItem = appMenu.addItem(withTitle: L10n.text("menu.archive"), action: #selector(openArchive), keyEquivalent: "l")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.text("menu.settings"), action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.text("menu.import"), action: #selector(importStickies), keyEquivalent: "i")
        appMenu.addItem(.separator())
        let bigger = appMenu.addItem(withTitle: L10n.text("menu.bigger_text"), action: #selector(biggerText), keyEquivalent: "+")
        bigger.keyEquivalentModifierMask = [.control]
        let smaller = appMenu.addItem(withTitle: L10n.text("menu.smaller_text"), action: #selector(smallerText), keyEquivalent: "-")
        smaller.keyEquivalentModifierMask = [.control]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.text("menu.hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: L10n.text("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // The three global shortcuts already carry ⌥; mirror that here so the menu
        // items do not shadow ⌘N / ⌘A / ⌘L inside text fields.
        for item in [newNoteItem, allNotesItem, archiveItem] {
            item.keyEquivalentModifierMask = [.command, .option]
        }
        for item in appMenu.items where item.action != nil
            && item.action != #selector(NSApplication.hide(_:))
            && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: L10n.text("menu.edit"))
        edit.addItem(withTitle: L10n.text("menu.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L10n.text("menu.redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L10n.text("menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L10n.text("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L10n.text("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L10n.text("menu.select_all"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}
