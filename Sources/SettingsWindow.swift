import AppKit
import SwiftUI
import Carbon.HIToolbox

// MARK: - Shortcut recorder

/// Captures a key combination. It has to intercept `performKeyEquivalent` as well
/// as `keyDown`, or combinations that match a menu item (⌘N and friends) are
/// swallowed by the menu before the field ever sees them.
final class RecorderView: NSView {
    var onCapture: ((Shortcut) -> Void)?
    /// In-note shortcuts are matched by the note itself, so a bare key is safe.
    /// A global one without a modifier would swallow that key system-wide.
    var allowsBareKeys = false
    var shortcut: Shortcut = .none { didSet { needsDisplay = true } }
    private var recording = false { didSet { needsDisplay = true } }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        recording = true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == UInt16(kVK_Escape) { stop(); return }
        if event.keyCode == UInt16(kVK_Delete) {
            shortcut = .none; onCapture?(.none); stop(); return
        }
        guard let s = Shortcut.from(event: event, allowingBareKey: allowsBareKeys) else {
            NSSound.beep()
            return
        }
        shortcut = s
        onCapture?(s)
        stop()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    private func stop() {
        recording = false
        window?.makeFirstResponder(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.12)
                   : NSColor.textBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor
                   : NSColor.separatorColor).setStroke()
        path.lineWidth = recording ? 2 : 1
        path.stroke()

        let text = recording ? L10n.text("shortcut.press_keys") : shortcut.display
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: recording ? .regular : .medium),
            .foregroundColor: recording ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: r.midX - size.width / 2,
                                            y: r.midY - size.height / 2), withAttributes: attrs)
    }
}

struct ShortcutField: NSViewRepresentable {
    let shortcut: Shortcut
    var allowsBareKeys = false
    let onChange: (Shortcut) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let v = RecorderView()
        v.shortcut = shortcut
        v.allowsBareKeys = allowsBareKeys
        v.onCapture = onChange
        return v
    }
    func updateNSView(_ v: RecorderView, context: Context) {
        v.shortcut = shortcut
        v.allowsBareKeys = allowsBareKeys
        v.onCapture = onChange
    }
}

// MARK: - Model

final class SettingsModel: ObservableObject {
    @Published var appLanguage: AppLanguage {
        didSet {
            guard !loading, !syncing, appLanguage != oldValue else { return }
            Settings.appLanguage = appLanguage
            (NSApp.delegate as? AppDelegate)?.relaunchForLanguageChange(previous: oldValue)
        }
    }
    @Published var deckStyle: DeckStyle { didSet { Settings.deckStyle = deckStyle; apply() } }
    @Published var alwaysShown: Bool    { didSet { Settings.deckAlwaysShown = alwaysShown; apply() } }
    @Published var pillHidden: Bool     { didSet { Settings.deckPillHidden = pillHidden; apply() } }
    @Published var hideActions: Bool    { didSet { Settings.deckHideActions = hideActions; apply() } }
    @Published var deckScale: Double    { didSet { Settings.deckScale = deckScale; apply() } }
    @Published var onLeftEdge: Bool     { didSet { Settings.deckOnLeftEdge = onLeftEdge; apply() } }
    @Published var displayTarget: String { didSet { Settings.displayTarget = displayTarget; apply() } }
    @Published var screens: [NSScreen] = NSScreen.screens
    @Published var edgeWidth: Double    { didSet { Settings.edgeWidth = edgeWidth; apply() } }
    @Published var overFullScreen: Bool { didSet { Settings.showOverFullScreen = overFullScreen; apply() } }
    @Published var confineToSpace: Bool { didSet { Settings.confineToSpace = confineToSpace; apply() } }
    @Published var launchAtLogin: Bool  { didSet { Settings.launchAtLogin = launchAtLogin } }

    @Published var autoUpdate: Bool {
        didSet { guard !loading else { return }; Updater.shared.automaticallyChecks = autoUpdate }
    }
    @Published var updateStatus: String = ""

    @Published var fontName: String     { didSet { Settings.noteFontName = fontName; apply() } }
    @Published var fontSize: Double     { didSet { Settings.noteFontSize = fontSize; apply() } }
    @Published var markdown: Bool       { didSet { Settings.markdownStyling = markdown; apply() } }
    @Published var noteSizeIndex: Int   { didSet { Settings.noteSizeIndex = noteSizeIndex; apply() } }
    @Published var openOnHover: Bool    { didSet { Settings.openOnHover = openOnHover; apply() } }
    @Published var tabPreview: Bool     { didSet { Settings.tabPreview = tabPreview; apply() } }

    @Published var cloudSync: Bool {
        didSet {
            guard !loading, cloudSync != oldValue else { return }
            Settings.cloudSyncEnabled = cloudSync
            CloudSync.shared.reload()
            refreshSyncStatus()
        }
    }
    @Published var syncStatus: String = ""

    @Published var scNewNote: Shortcut  { didSet { Settings.scNewNote = scNewNote; HotKeys.shared.reload() } }
    @Published var scAllNotes: Shortcut { didSet { Settings.scAllNotes = scAllNotes; HotKeys.shared.reload() } }
    @Published var scGlobalSearch: Shortcut { didSet { Settings.scGlobalSearch = scGlobalSearch; HotKeys.shared.reload() } }
    @Published var scArchive: Shortcut  { didSet { Settings.scArchive = scArchive; HotKeys.shared.reload() } }
    @Published var scCapture: Shortcut  { didSet { Settings.scCapture = scCapture; HotKeys.shared.reload() } }
    // Handled by the open note itself, so these need no hotkey registration.
    @Published var scArchiveNote: Shortcut { didSet { Settings.scArchiveNote = scArchiveNote } }
    @Published var scClose: Shortcut   { didSet { Settings.scClose = scClose } }
    @Published var scFind: Shortcut    { didSet { Settings.scFind = scFind } }
    @Published var scTask: Shortcut    { didSet { Settings.scTask = scTask } }
    @Published var scPin: Shortcut     { didSet { Settings.scPin = scPin } }
    @Published var scColour: Shortcut  { didSet { Settings.scColour = scColour } }
    @Published var scDelete: Shortcut  { didSet { Settings.scDelete = scDelete } }
    @Published var scBigger: Shortcut  { didSet { Settings.scBigger = scBigger } }
    @Published var scSmaller: Shortcut { didSet { Settings.scSmaller = scSmaller } }

    private var loading = true
    /// True while values are applied back from UserDefaults (e.g. after a
    /// failed relaunch) — those writes must not re-trigger another relaunch.
    private var syncing = false

    init() {
        appLanguage = Settings.appLanguage
        deckStyle = Settings.deckStyle
        alwaysShown = Settings.deckAlwaysShown
        pillHidden = Settings.deckPillHidden
        hideActions = Settings.deckHideActions
        deckScale = Settings.deckScale
        onLeftEdge = Settings.deckOnLeftEdge
        displayTarget = Settings.displayTarget
        screens = NSScreen.screens
        edgeWidth = Settings.edgeWidth
        overFullScreen = Settings.showOverFullScreen
        confineToSpace = Settings.confineToSpace
        launchAtLogin = Settings.launchAtLogin
        autoUpdate = Updater.available && Updater.shared.automaticallyChecks
        fontName = Settings.noteFontName
        fontSize = Settings.noteFontSize
        markdown = Settings.markdownStyling
        noteSizeIndex = Settings.noteSizeIndex
        openOnHover = Settings.openOnHover
        tabPreview = Settings.tabPreview
        cloudSync = Settings.cloudSyncEnabled
        scNewNote = Settings.scNewNote
        scAllNotes = Settings.scAllNotes
        scGlobalSearch = Settings.scGlobalSearch
        scArchive = Settings.scArchive
        scCapture = Settings.scCapture
        scArchiveNote = Settings.scArchiveNote
        scClose = Settings.scClose
        scFind = Settings.scFind
        scTask = Settings.scTask
        scPin = Settings.scPin
        scColour = Settings.scColour
        scDelete = Settings.scDelete
        scBigger = Settings.scBigger
        scSmaller = Settings.scSmaller
        loading = false
        refreshUpdateStatus()
        refreshSyncStatus()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.screens = NSScreen.screens
            }
    }

    /// Re-read a handful of values straight from UserDefaults without firing
    /// their didSet side-effects — used after a failed language-change relaunch
    /// to roll the picker back to what the running process actually speaks.
    func syncFromDefaults() {
        syncing = true
        appLanguage = Settings.appLanguage
        displayTarget = Settings.displayTarget
        tabPreview = Settings.tabPreview
        syncing = false
    }

    private func apply() {
        guard !loading else { return }
        (NSApp.delegate as? AppDelegate)?.refreshDecks()
    }

    func refreshUpdateStatus() {
        guard Updater.available else {
            updateStatus = L10n.text("updates.no_sparkle_status")
            return
        }
        guard let last = Updater.shared.lastCheck else {
            updateStatus = L10n.text("updates.not_checked")
            return
        }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        updateStatus = L10n.format("updates.last_checked", f.localizedString(for: last, relativeTo: Date()))
    }

    func refreshSyncStatus() {
        guard Settings.cloudSyncEnabled else {
            syncStatus = L10n.text("settings.sync.status_off")
            return
        }
        guard CloudFolder.isAvailable else {
            syncStatus = L10n.text("settings.sync.status_unavailable")
            return
        }
        guard let last = CloudSync.shared.lastSync else {
            syncStatus = L10n.text("settings.sync.status_never")
            return
        }
        syncStatus = L10n.format("settings.sync.status_last", Fmt.ago(last))
    }

    func syncNow() {
        CloudSync.shared.syncNow()
        refreshSyncStatus()
    }

    func revealSyncFolder() {
        CloudFolder.ensureFolder()
        NSWorkspace.shared.activateFileViewerSelecting([CloudFolder.url])
    }

    func checkForUpdatesNow() {
        Updater.shared.checkForUpdates()
        // Sparkle stamps the date when its own check finishes, not when it is
        // asked, so the status line has to be read back a moment later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.refreshUpdateStatus()
        }
    }

    /// Warn about a combination already used by another Noty shortcut.
    func duplicate(of s: Shortcut, ignoring label: String) -> Bool {
        guard s.isSet else { return false }
        let others = [("new", scNewNote), ("all", scAllNotes), ("archive", scArchive),
                      ("capture", scCapture), ("search", scGlobalSearch),
                      ("archiveNote", scArchiveNote), ("close", scClose), ("find", scFind),
                      ("task", scTask), ("pin", scPin), ("colour", scColour),
                      ("delete", scDelete), ("bigger", scBigger), ("smaller", scSmaller)]
            .filter { $0.0 != label }
        return others.contains { $0.1 == s }
    }
}

// MARK: - Window

final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private let model = SettingsModel()

    var isOpen: Bool { window?.isVisible ?? false }

    func syncPreferences() {
        model.syncFromDefaults()
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = L10n.text("settings.window_title")
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: SettingsView(model: model))
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        AppWindows.didClose(notification)
    }
}

// MARK: - View

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var hotKeys = HotKeys.shared

    var body: some View {
        // One long scroll made twelve shortcut fields, nine deck controls and the
        // note settings compete for the same eye. Tabs are what a Settings window
        // is supposed to be, and they leave somewhere obvious to put updates.
        TabView {
            pane { shortcutsTab }
                .tabItem { Label(L10n.text("settings.shortcuts.tab"), systemImage: "command") }
            pane { deckTab }
                .tabItem { Label(L10n.text("settings.deck.tab"), systemImage: "menucard") }
            pane { notesTab }
                .tabItem { Label(L10n.text("settings.notes.tab"), systemImage: "textformat") }
            pane { syncTab }
                .tabItem { Label(L10n.text("settings.sync.tab"), systemImage: "icloud") }
            pane { updatesTab }
                .tabItem { Label(L10n.text("settings.updates.tab"), systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(width: 600, height: 500)
    }

    // MARK: tabs

    @ViewBuilder
    private var shortcutsTab: some View {
        Section {
            shortcutRow(L10n.text("shortcut.new_note"), model.scNewNote, "new") { model.scNewNote = $0 }
            shortcutRow(L10n.text("shortcut.all_notes"), model.scAllNotes, "all") { model.scAllNotes = $0 }
            shortcutRow(L10n.text("search.title"), model.scGlobalSearch, "search") { model.scGlobalSearch = $0 }
            shortcutRow(L10n.text("shortcut.archive_window"), model.scArchive, "archive") { model.scArchive = $0 }
            shortcutRow(L10n.text("shortcut.quick_capture"), model.scCapture, "capture") { model.scCapture = $0 }
        } header: {
            Text(L10n.text("settings.shortcuts.global"))
        } footer: {
            Text(L10n.text("settings.shortcuts.caption"))
        }
        Section {
            shortcutRow(L10n.text("action.close"), model.scClose, "close", bare: true) { model.scClose = $0 }
            shortcutRow(L10n.text("shortcut.archive_note"), model.scArchiveNote, "archiveNote", bare: true) { model.scArchiveNote = $0 }
            shortcutRow(L10n.text("action.delete"), model.scDelete, "delete", bare: true) { model.scDelete = $0 }
            shortcutRow(L10n.text("action.find"), model.scFind, "find", bare: true) { model.scFind = $0 }
            shortcutRow(L10n.text("shortcut.toggle_task"), model.scTask, "task", bare: true) { model.scTask = $0 }
            shortcutRow(L10n.text("action.pin"), model.scPin, "pin", bare: true) { model.scPin = $0 }
            shortcutRow(L10n.text("action.cycle_colour"), model.scColour, "colour", bare: true) { model.scColour = $0 }
            shortcutRow(L10n.text("menu.bigger_text"), model.scBigger, "bigger", bare: true) { model.scBigger = $0 }
            shortcutRow(L10n.text("menu.smaller_text"), model.scSmaller, "smaller", bare: true) { model.scSmaller = $0 }
        } header: {
            Text(L10n.text("settings.shortcuts.in_note"))
        } footer: {
            Text(L10n.text("settings.shortcuts.hint"))
        }
    }

    @ViewBuilder
    private var deckTab: some View {
        Section {
            LabeledContent {
                Picker("", selection: $model.appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.localizedName).tag(language)
                    }
                }
                .labelsHidden()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("settings.deck.language"))
                    Text(L10n.text("settings.deck.language_help"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(L10n.text("settings.deck.caption"))
        }
        Section {
            LabeledContent(L10n.text("settings.deck.style")) {
                Picker("", selection: $model.deckStyle) {
                    ForEach(DeckStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().pickerStyle(.segmented)
            }
            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: $model.deckScale,
                           in: Settings.deckScaleRange.lowerBound...Settings.deckScaleRange.upperBound,
                           step: 0.05).frame(width: 210)
                    Text("\(Int((model.deckScale * 100).rounded()))%")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("settings.deck.size"))
                    Text(L10n.text("settings.deck.size_help"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if model.screens.count > 1 {
                LabeledContent(L10n.text("settings.deck.display")) {
                    Picker("", selection: $model.displayTarget) {
                        Text(L10n.text("display.all")).tag("all")
                        Text(L10n.text("display.main")).tag("main")
                        ForEach(model.screens, id: \.self) { s in
                            if let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value {
                                let name = s.localizedName
                                let title = s == NSScreen.main ? L10n.format("display.named_main", name) : name
                                Text(title).tag("id:\(id)")
                            }
                        }
                    }.labelsHidden()
                }
            }
            LabeledContent(L10n.text("settings.deck.edge")) {
                Picker("", selection: $model.onLeftEdge) {
                    Text(L10n.text("edge.right")).tag(false); Text(L10n.text("edge.left")).tag(true)
                }.labelsHidden().pickerStyle(.segmented)
            }
            LabeledContent {
                Picker("", selection: $model.edgeWidth) {
                    ForEach(Settings.edgeWidths, id: \.width) { Text(L10n.text($0.nameKey)).tag($0.width) }
                }.labelsHidden().pickerStyle(.segmented)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("settings.deck.detection_area"))
                    Text(L10n.format("settings.deck.detection_help", Int(model.edgeWidth)))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        Section {
            toggleRow(L10n.text("settings.deck.keep_open"),
                      help: L10n.text("settings.deck.keep_open_help"),
                      isOn: $model.alwaysShown)
            // Only meaningful while the deck is kept open — hidden otherwise
            // rather than sitting there doing nothing.
            if model.alwaysShown {
                toggleRow(L10n.text("settings.deck.hide_actions"),
                          help: L10n.text("settings.deck.hide_actions_help"),
                          isOn: $model.hideActions)
            }
            toggleRow(L10n.text("settings.deck.hide_pill"),
                      help: L10n.text("settings.deck.hide_pill_help"),
                      isOn: $model.pillHidden)
            // Pointless alongside hover-to-open — the note itself opens — so the
            // row disappears rather than sitting there doing nothing.
            if !model.openOnHover {
                toggleRow(L10n.text("settings.deck.hover_preview"),
                          help: L10n.text("settings.deck.hover_preview_help"),
                          isOn: $model.tabPreview)
            }
            toggleRow(L10n.text("settings.deck.hover_open"),
                      help: L10n.text("settings.deck.hover_open_help"),
                      isOn: $model.openOnHover)
            toggleRow(L10n.text("menu.show_over_fullscreen"), isOn: $model.overFullScreen)
            toggleRow(L10n.text("settings.deck.one_space"),
                      help: L10n.text("settings.deck.one_space_help"),
                      isOn: $model.confineToSpace)
            toggleRow(L10n.text("menu.launch_at_login"), isOn: $model.launchAtLogin)
        } footer: {
            Text(L10n.text("settings.deck.drag_help"))
        }
    }

    @ViewBuilder
    private var notesTab: some View {
        Section {
            LabeledContent(L10n.text("settings.notes.font")) {
                Picker("", selection: $model.fontName) {
                    Section(L10n.text("font.curated")) {
                        ForEach(Ink.faces, id: \.body) {
                            Text($0.localizedName).tag($0.body)
                        }
                    }
                    Section(L10n.text("font.system_fonts")) {
                        ForEach(Ink.allSystemFontFamilies, id: \.family) { family in
                            Text(family.family)
                                .tag(family.members.first?.postScript ?? "")
                        }
                    }
                }.labelsHidden()
            }
            LabeledContent(L10n.text("settings.notes.note_size")) {
                Picker("", selection: $model.noteSizeIndex) {
                    ForEach(Array(Settings.noteSizes.enumerated()), id: \.offset) { i, s in
                        Text(L10n.text(s.nameKey)).tag(i)
                    }
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            LabeledContent(L10n.text("settings.notes.text_size")) {
                HStack(spacing: 10) {
                    Slider(value: $model.fontSize,
                           in: Settings.fontRange.lowerBound...Settings.fontRange.upperBound,
                           step: 0.5).frame(width: 210)
                    Text(L10n.format("settings.notes.font_size_value", model.fontSize))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                }
            }
        } header: {
            Text(L10n.text("settings.notes.caption"))
        }
        Section {
            toggleRow(L10n.text("settings.notes.markdown"),
                      help: L10n.text("settings.notes.markdown_help"),
                      isOn: $model.markdown)
        }
    }

    @ViewBuilder
    private var syncTab: some View {
        Section {
            toggleRow(L10n.text("settings.sync.enable"),
                      help: L10n.text("settings.sync.enable_help"),
                      isOn: $model.cloudSync,
                      disabled: !CloudFolder.isAvailable)
            if !CloudFolder.isAvailable {
                Text(L10n.text("settings.sync.unavailable_help"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            LabeledContent(L10n.text("settings.sync.status")) {
                HStack(spacing: 10) {
                    Text(model.syncStatus)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Button(L10n.text("settings.sync.sync_now")) { model.syncNow() }
                        .disabled(!model.cloudSync || !CloudFolder.isAvailable)
                }
            }
            LabeledContent(L10n.text("settings.sync.folder")) {
                HStack(spacing: 10) {
                    Text(CloudFolder.url.path)
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                    Button(L10n.text("settings.sync.reveal")) { model.revealSyncFolder() }
                        .disabled(!CloudFolder.isAvailable)
                }
            }
        } header: {
            Text(L10n.text("settings.sync.caption"))
        }
    }

    @ViewBuilder
    private var updatesTab: some View {
        Section {
            LabeledContent(L10n.text("settings.updates.this_copy")) {
                Text(Self.versionString)
                    .font(.system(size: 12.5).monospacedDigit())
            }
            toggleRow(L10n.text("settings.updates.automatic"),
                      help: model.updateStatus,
                      isOn: $model.autoUpdate,
                      disabled: !Updater.available)
            HStack(spacing: 10) {
                Button(L10n.text("settings.updates.check_now")) { model.checkForUpdatesNow() }
                    .disabled(!Updater.available)
                if !Updater.available {
                    Text(L10n.text("updates.install_sparkle"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(L10n.text("settings.updates.caption"))
        } footer: {
            Text(L10n.text("settings.updates.privacy"))
        }
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return L10n.format("settings.updates.version", short, build)
    }

    // MARK: pieces

    /// One tab, laid out by the system: grouped form cells align every label
    /// column and control edge themselves.
    private func pane(@ViewBuilder _ content: () -> some View) -> some View {
        Form {
            content()
        }
        .formStyle(.grouped)
        .onAppear {
            model.refreshUpdateStatus()
            model.refreshSyncStatus()
        }
    }

    /// The standard settings cell: title and its explanation on the left, the
    /// switch on the right.
    private func toggleRow(_ title: String, help: String? = nil,
                           isOn: Binding<Bool>, disabled: Bool = false) -> some View {
        LabeledContent {
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(disabled)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let help {
                    Text(help)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func shortcutRow(_ label: String, _ value: Shortcut, _ key: String,
                             bare: Bool = false,
                             _ set: @escaping (Shortcut) -> Void) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                ShortcutField(shortcut: value, allowsBareKeys: bare, onChange: set)
                    .frame(width: 96, height: 24)
                if model.duplicate(of: value, ignoring: key) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                        .help(L10n.text("shortcut.duplicate"))
                } else if !bare && hotKeys.unavailableShortcuts.contains(value) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                        .help(L10n.text("shortcut.unavailable"))
                }
            }
        }
    }
}
