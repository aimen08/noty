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
    @Published var deckScale: Double    { didSet { Settings.deckScale = deckScale; apply() } }
    @Published var onLeftEdge: Bool     { didSet { Settings.deckOnLeftEdge = onLeftEdge; apply() } }
    @Published var displayTarget: String { didSet { Settings.displayTarget = displayTarget; apply() } }
    @Published var screens: [NSScreen] = NSScreen.screens
    @Published var edgeWidth: Double    { didSet { Settings.edgeWidth = edgeWidth; apply() } }
    @Published var overFullScreen: Bool { didSet { Settings.showOverFullScreen = overFullScreen; apply() } }
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

    @Published var scNewNote: Shortcut  { didSet { Settings.scNewNote = scNewNote; HotKeys.shared.reload() } }
    @Published var scAllNotes: Shortcut { didSet { Settings.scAllNotes = scAllNotes; HotKeys.shared.reload() } }
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
        deckScale = Settings.deckScale
        onLeftEdge = Settings.deckOnLeftEdge
        displayTarget = Settings.displayTarget
        screens = NSScreen.screens
        edgeWidth = Settings.edgeWidth
        overFullScreen = Settings.showOverFullScreen
        launchAtLogin = Settings.launchAtLogin
        autoUpdate = Updater.available && Updater.shared.automaticallyChecks
        fontName = Settings.noteFontName
        fontSize = Settings.noteFontSize
        markdown = Settings.markdownStyling
        noteSizeIndex = Settings.noteSizeIndex
        openOnHover = Settings.openOnHover
        tabPreview = Settings.tabPreview
        scNewNote = Settings.scNewNote
        scAllNotes = Settings.scAllNotes
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
                      ("capture", scCapture),
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
        DispatchQueue.main.async {
            if LibraryWindow.shared.isOpen == false { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

// MARK: - View

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        // One long scroll made twelve shortcut fields, nine deck controls and the
        // note settings compete for the same eye. Tabs are what a Settings window
        // is supposed to be, and they leave somewhere obvious to put updates.
        TabView {
            pane(L10n.text("settings.shortcuts.caption")) { shortcutsTab }
                .tabItem { Label(L10n.text("settings.shortcuts.tab"), systemImage: "command") }
            pane(L10n.text("settings.deck.caption")) { deckTab }
                .tabItem { Label(L10n.text("settings.deck.tab"), systemImage: "menucard") }
            pane(L10n.text("settings.notes.caption")) { notesTab }
                .tabItem { Label(L10n.text("settings.notes.tab"), systemImage: "textformat") }
            pane(L10n.text("settings.updates.caption")) { updatesTab }
                .tabItem { Label(L10n.text("settings.updates.tab"), systemImage: "arrow.triangle.2.circlepath") }
        }
        .padding(14)
        .frame(width: 600, height: 500)
    }

    @ViewBuilder
    private var shortcutsTab: some View {
        // Two columns: twelve stacked rows made the window scroll for
        // what is really a reference table.
        HStack(alignment: .top, spacing: 26) {
            VStack(alignment: .leading, spacing: 7) {
                subhead(L10n.text("settings.shortcuts.global"))
                shortcutRow(L10n.text("shortcut.new_note"), model.scNewNote, "new") { model.scNewNote = $0 }
                shortcutRow(L10n.text("shortcut.all_notes"), model.scAllNotes, "all") { model.scAllNotes = $0 }
                shortcutRow(L10n.text("shortcut.archive_window"), model.scArchive, "archive") { model.scArchive = $0 }
                shortcutRow(L10n.text("shortcut.quick_capture"), model.scCapture, "capture") { model.scCapture = $0 }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 7) {
                subhead(L10n.text("settings.shortcuts.in_note"))
                shortcutRow(L10n.text("action.close"), model.scClose, "close", bare: true) { model.scClose = $0 }
                shortcutRow(L10n.text("shortcut.archive_note"), model.scArchiveNote, "archiveNote", bare: true) { model.scArchiveNote = $0 }
                shortcutRow(L10n.text("action.delete"), model.scDelete, "delete", bare: true) { model.scDelete = $0 }
                shortcutRow(L10n.text("action.find"), model.scFind, "find", bare: true) { model.scFind = $0 }
                shortcutRow(L10n.text("shortcut.toggle_task"), model.scTask, "task", bare: true) { model.scTask = $0 }
                shortcutRow(L10n.text("action.pin"), model.scPin, "pin", bare: true) { model.scPin = $0 }
                shortcutRow(L10n.text("action.cycle_colour"), model.scColour, "colour", bare: true) { model.scColour = $0 }
                shortcutRow(L10n.text("menu.bigger_text"), model.scBigger, "bigger", bare: true) { model.scBigger = $0 }
                shortcutRow(L10n.text("menu.smaller_text"), model.scSmaller, "smaller", bare: true) { model.scSmaller = $0 }
            }
        }
        Text(L10n.text("settings.shortcuts.hint"))
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
    }

    @ViewBuilder
    private var deckTab: some View {
        row(L10n.text("settings.deck.language")) {
            VStack(alignment: .leading, spacing: 4) {
                Picker("", selection: $model.appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.localizedName).tag(language)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
                Text(L10n.text("settings.deck.language_help"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        Divider().padding(.vertical, 2)
        row(L10n.text("settings.deck.style")) {
            Picker("", selection: $model.deckStyle) {
                ForEach(DeckStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }.labelsHidden().pickerStyle(.segmented).frame(width: 240)
        }
        row(L10n.text("settings.deck.size")) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Slider(value: $model.deckScale,
                           in: Settings.deckScaleRange.lowerBound...Settings.deckScaleRange.upperBound,
                           step: 0.05).frame(width: 210)
                    Text("\(Int((model.deckScale * 100).rounded()))%")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                }
                Text(L10n.text("settings.deck.size_help"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        if model.screens.count > 1 {
            row(L10n.text("settings.deck.display")) {
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
                }.labelsHidden().frame(width: 220)
            }
        }
        row(L10n.text("settings.deck.edge")) {
            Picker("", selection: $model.onLeftEdge) {
                Text(L10n.text("edge.right")).tag(false); Text(L10n.text("edge.left")).tag(true)
            }.labelsHidden().pickerStyle(.segmented).frame(width: 160)
        }
        row(L10n.text("settings.deck.detection_area")) {
            VStack(alignment: .leading, spacing: 4) {
                Picker("", selection: $model.edgeWidth) {
                    ForEach(Settings.edgeWidths, id: \.width) { Text(L10n.text($0.nameKey)).tag($0.width) }
                }.labelsHidden().pickerStyle(.segmented).frame(width: 300)
                Text(L10n.format("settings.deck.detection_help", Int(model.edgeWidth)))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        VStack(alignment: .leading, spacing: 3) {
            Toggle(L10n.text("settings.deck.keep_open"), isOn: $model.alwaysShown)
            Text(L10n.text("settings.deck.keep_open_help"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Pointless alongside hover-to-open — the note itself opens — so the
        // row disappears rather than sitting there doing nothing.
        if !model.openOnHover {
            VStack(alignment: .leading, spacing: 3) {
                Toggle(L10n.text("settings.deck.hover_preview"), isOn: $model.tabPreview)
                Text(L10n.text("settings.deck.hover_preview_help"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        VStack(alignment: .leading, spacing: 3) {
            Toggle(L10n.text("settings.deck.hover_open"), isOn: $model.openOnHover)
            Text(L10n.text("settings.deck.hover_open_help"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        Toggle(L10n.text("menu.show_over_fullscreen"), isOn: $model.overFullScreen)
        Toggle(L10n.text("menu.launch_at_login"), isOn: $model.launchAtLogin)
        Text(L10n.text("settings.deck.drag_help"))
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.top, 2)
    }

    @ViewBuilder
    private var notesTab: some View {
        row(L10n.text("settings.notes.font")) {
            Picker("", selection: $model.fontName) {
                ForEach(Ink.faces, id: \.body) { Text($0.localizedName).tag($0.body) }
            }.labelsHidden().frame(width: 200)
        }
        row(L10n.text("settings.notes.note_size")) {
            Picker("", selection: $model.noteSizeIndex) {
                ForEach(Array(Settings.noteSizes.enumerated()), id: \.offset) { i, s in
                    Text(L10n.text(s.nameKey)).tag(i)
                }
            }
            .labelsHidden().pickerStyle(.segmented).frame(width: 300)
        }
        row(L10n.text("settings.notes.text_size")) {
            HStack(spacing: 10) {
                Slider(value: $model.fontSize,
                       in: Settings.fontRange.lowerBound...Settings.fontRange.upperBound,
                       step: 0.5).frame(width: 210)
                Text(L10n.format("settings.notes.font_size_value", model.fontSize))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            }
        }
        VStack(alignment: .leading, spacing: 3) {
            Toggle(L10n.text("settings.notes.markdown"), isOn: $model.markdown)
            Text(L10n.text("settings.notes.markdown_help"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
    }

    @ViewBuilder
    private var updatesTab: some View {
        row(L10n.text("settings.updates.this_copy")) {
            Text(Self.versionString)
                .font(.system(size: 12.5).monospacedDigit())
        }
        VStack(alignment: .leading, spacing: 3) {
            Toggle(L10n.text("settings.updates.automatic"), isOn: $model.autoUpdate)
                .disabled(!Updater.available)
            Text(model.updateStatus)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 10) {
            Button(L10n.text("settings.updates.check_now")) { model.checkForUpdatesNow() }
                .disabled(!Updater.available)
            if !Updater.available {
                Text(L10n.text("updates.install_sparkle"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        Divider().padding(.vertical, 4)
        Text(L10n.text("settings.updates.privacy"))
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return L10n.format("settings.updates.version", short, build)
    }

    // MARK: pieces

    /// One tab. The heading is gone — the tab itself is the heading now — but the
    /// caption earns its line, so it stays.
    private func pane(_ caption: String,
                      @ViewBuilder _ content: () -> some View) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                Text(caption).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 11) { content() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .onAppear { model.refreshUpdateStatus() }
    }

    private func subhead(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func row(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label).font(.system(size: 12.5))
                .frame(width: 104, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func shortcutRow(_ label: String, _ value: Shortcut, _ key: String,
                             bare: Bool = false,
                             _ set: @escaping (Shortcut) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12)).frame(width: 96, alignment: .leading)
            ShortcutField(shortcut: value, allowsBareKeys: bare, onChange: set)
                .frame(width: 96, height: 24)
            if model.duplicate(of: value, ignoring: key) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10)).foregroundStyle(.orange)
                    .help(L10n.text("shortcut.duplicate"))
            }
            Spacer(minLength: 0)
        }
    }
}
