import AppKit
import SwiftUI
import Combine

// MARK: - Deck state

enum DeckState: Equatable {
    case rest
    case fan
    case expanded(String)

    var rank: Int {
        switch self {
        case .rest: return 0
        case .fan: return 1
        case .expanded: return 2
        }
    }
    var expandedID: String? {
        if case .expanded(let id) = self { return id }
        return nil
    }
}

final class DeckModel: ObservableObject {
    @Published var state: DeckState = .rest
    @Published var showAll = false          // "+N more" opened into a scrolling list
    @Published var findQuery: String?       // nil = find bar hidden
    @Published var revealTick = 0           // bumped to restage the fan animation

    /// Owns the NSTextView of the open note so ⌘F can drive it.
    let bridge = EditorBridge()

    /// The deck shows tabs in every state except rest.
    var fanVisible: Bool { state != .rest }

    // Mirrored from Settings so SwiftUI re-renders when a preference flips.
    @Published var style: DeckStyle = Settings.deckStyle
    @Published var alwaysShown: Bool = Settings.deckAlwaysShown
    /// DeckGeom reads the scale straight from Settings; this mirror exists purely
    /// so a change to it invalidates the views that measure against it.
    @Published var scale: Double = Settings.deckScale
    @Published var onLeftEdge: Bool = Settings.deckOnLeftEdge
    @Published var fontSize: Double = Settings.noteFontSize
    @Published var markdown: Bool = Settings.markdownStyling
    @Published var noteSize = Settings.noteSize
    @Published var openOnHover: Bool = Settings.openOnHover
    @Published var tabPreview: Bool = Settings.tabPreview
    /// Set while a tab is being dragged. The deck must not tidy itself away
    /// mid-drag just because the pointer strayed out of the edge strip.
    @Published var isDragging = false
    /// The note's height at the moment it opened. Its top is anchored from this
    /// and nothing else — recomputing the position from a height that changes
    /// mid-resize makes the note jump the instant the drag ends.
    @Published var openedHeight: CGFloat = Settings.noteSize.height
    /// The note's top offset at the moment it opened. Anchored so title edits
    /// and autosaves while typing never make the open note jump or flicker.
    @Published var openedTop: CGFloat?

    func syncPreferences() {
        style = Settings.deckStyle
        alwaysShown = Settings.deckAlwaysShown
        scale = Settings.deckScale
        onLeftEdge = Settings.deckOnLeftEdge
        fontSize = Settings.noteFontSize
        markdown = Settings.markdownStyling
        noteSize = Settings.noteSize
        openOnHover = Settings.openOnHover
        tabPreview = Settings.tabPreview
    }
}

// MARK: - Controller

/// One deck per physical display. Keyed by CGDirectDisplayID because NSScreen
/// instances are replaced wholesale on display reconfiguration.
final class DeckController: NSObject {
    let displayID: CGDirectDisplayID
    let model = DeckModel()

    private let panel = DeckPanel()
    private var hosting: DeckHostingView<DeckRootView>!
    private var container: DeckContentView!
    private var keyMonitor: Any?
    private var outsideMonitor: Any?
    private var idleTimer: Timer?
    private var lastActivity = Date()
    private var lastPointer = NSEvent.mouseLocation
    private var exitWork: DispatchWorkItem?     // debounced pointer-exit check
    private var shrinkWork: DispatchWorkItem?   // delayed panel shrink after collapse
    private var bag = Set<AnyCancellable>()

    weak var manager: DeckManager?

    /// Where the deck sits when nothing is happening: the pill, or the tabs
    /// themselves once the user has asked for them to stay put.
    private var restingState: DeckState { Settings.deckAlwaysShown ? .fan : .rest }

    var screen: NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        super.init()

        container = DeckContentView()
        container.controller = self
        container.autoresizingMask = [.width, .height]

        hosting = DeckHostingView(rootView: DeckRootView(deck: model, controller: self))
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = container.bounds
        container.addSubview(hosting)

        panel.contentView = container
        model.state = restingState
        layout()
        panel.orderFrontRegardless()

        // Pill height tracks the note count.
        NoteStore.shared.$notes
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.model.state == .rest else { return }
                self.layout()
            }
            .store(in: &bag)
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        idleTimer?.invalidate()
        panel.orderOut(nil)
    }

    // MARK: Layout

    func layout() { layout(for: model.state) }

    func layout(for state: DeckState) {
        guard let screen else { return }
        let full = screen.frame
        let vis = screen.visibleFrame
        let onRight = !Settings.deckOnLeftEdge

        let frame: NSRect
        switch state {
        case .rest:
            let h = DeckGeom.pillHeight(noteCount: max(1, NoteStore.shared.active.count))
            // The dormant panel is the detection strip: the pill is drawn at the
            // edge and the rest of the width is transparent and click-through.
            let w = max(DeckGeom.pillWidth + 2, CGFloat(Settings.edgeWidth))
            let availableH = max(1, vis.height - h)
            let y = vis.minY + availableH * Settings.deckYRatio
            frame = NSRect(x: onRight ? full.maxX - w : full.minX,
                           y: round(y), width: w, height: h)
        case .fan, .expanded:
            // Same width for both. Resizing the panel as a note opens makes the
            // window resize and SwiftUI's relayout land in different frames, and
            // for one frame the deck draws against the panel's far edge — which
            // looks exactly like the note flying in from mid-screen.
            // Width follows the note's live size, so a resize drag does not have
            // to round-trip through UserDefaults to widen the panel.
            let w = DeckGeom.expandedWidth
            frame = NSRect(x: onRight ? full.maxX - w : full.minX,
                           y: vis.minY, width: w, height: vis.height)
        }
        panel.setFrame(frame, display: true, animate: false)
    }

    func refreshLevel() {
        panel.applyLevel()
        panel.orderFrontRegardless()
    }

    // MARK: Transitions

    private func setState(_ new: DeckState) {
        let old = model.state
        guard old != new else { return }
        shrinkWork?.cancel(); shrinkWork = nil
        DeckLog.line("setState \(old) -> \(new)  panel=\(Int(panel.frame.width))x\(Int(panel.frame.height))")

        if new.rank >= old.rank {
            layout(for: new)
            if new == .fan {
                model.state = new
                model.revealTick &+= 1
            } else {
                // The panel has to be its final size *and rendered* before the note
                // animates in. `main.async` is not enough — SwiftUI coalesces the
                // resize and the state change into one pass, and then animates the
                // container's width, dragging the whole deck across the screen with
                // it. Two display frames of delay keeps them in separate passes.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0 / 60.0) {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        self.model.state = new
                    }
                }
            }
        } else {
            // Let the exit animation play at full size, then shrink the panel.
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                self.model.state = new
            }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                DeckLog.line("shrink fires; state=\(self.model.state)")
                self.layout()
            }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }

        noteActivity()
        if new.expandedID != nil {
            installKeyMonitor(); installOutsideMonitor()
        } else {
            removeKeyMonitor(); removeOutsideMonitor()
        }
        // A deck that is already at rest has nothing to tidy away, so the poll
        // only runs above the resting state — with the tabs kept open, that means
        // it runs for an open note and not for the fan.
        if new.rank > restingState.rank { startIdleWatch() } else { stopIdleWatch() }
        if new == restingState { model.showAll = false; model.findQuery = nil }
    }

    /// Anything the user does keeps the deck awake.
    func noteActivity() { lastActivity = Date() }

    /// A deck left untouched tidies itself away: the fan after a few seconds, an
    /// open note after a minute. Polling the pointer avoids needing mouse-moved
    /// events (and the permissions that can come with watching them globally).
    private func startIdleWatch() {
        guard idleTimer == nil else { return }
        lastActivity = Date()
        lastPointer = NSEvent.mouseLocation
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = NSEvent.mouseLocation
            // The panel is wider than the deck, so the tracking area cannot tell us
            // the pointer has left the tabs; compare against the strip instead.
            if self.model.state == .fan, !self.model.isDragging,
               !self.hotZone.contains(now) {
                self.collapse(); return
            }
            if self.model.isDragging { self.lastActivity = Date(); return }
            if abs(now.x - self.lastPointer.x) > 2 || abs(now.y - self.lastPointer.y) > 2 {
                self.lastPointer = now
                self.lastActivity = Date()
            }
            let idle = Date().timeIntervalSince(self.lastActivity)
            switch self.model.state {
            case .fan where idle > Settings.fanIdleTimeout:
                self.collapse()
            case .expanded where idle > Settings.noteIdleTimeout && !self.openNoteIsPinned:
                self.dismiss()
            default: break
            }
        }
    }

    private func stopIdleWatch() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    func pointerEntered() {
        noteActivity()
        exitWork?.cancel(); exitWork = nil
        shrinkWork?.cancel(); shrinkWork = nil
        DeckLog.line("pointerEntered state=\(model.state) panel=\(Int(panel.frame.width))")
        guard !NSEvent.modifierFlags.contains(.option) else { return }
        guard model.state == .rest else { layout(); return }
        manager?.deckDidActivate(self)
        setState(.fan)
    }

    /// Whether an ⌥-click should pick the deck up. "Keep the deck open" makes
    /// the fan the resting state, and the pill is then never the thing on screen
    /// to grab — without this the two preferences cancel each other out.
    var canBeginPillDrag: Bool { model.state == restingState }

    /// Interactive drag triggered when clicking the pill with ⌥ Option held.
    /// Moves the pill across screens and snaps to the nearest edge (left/right) at the cursor's height.
    func beginPillDrag(with initialEvent: NSEvent) {
        exitWork?.cancel(); exitWork = nil
        shrinkWork?.cancel(); shrinkWork = nil

        if model.state != .rest {
            setState(.rest)
        }

        model.isDragging = true
        noteActivity()
        NSCursor.closedHand.push()

        defer {
            NSCursor.pop()
            model.isDragging = false
            refreshLevel()
        }

        var targetScreen: NSScreen = self.screen ?? NSScreen.main ?? NSScreen.screens.first!
        var targetOnLeft = Settings.deckOnLeftEdge
        var targetYRatio = Settings.deckYRatio

        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp, .flagsChanged]

        while true {
            // A nested modal loop on the main thread: waiting on .distantFuture
            // wedges the whole app if the mouse-up is ever delivered elsewhere,
            // so poll and check the button instead.
            guard let event = NSApp.nextEvent(matching: mask,
                                              until: Date(timeIntervalSinceNow: 0.1),
                                              inMode: .eventTracking, dequeue: true) else {
                if NSEvent.pressedMouseButtons & 1 == 0 { break }
                continue
            }
            if event.type == .leftMouseUp {
                break
            }

            let p = NSEvent.mouseLocation
            if let s = NSScreen.screens.first(where: { $0.frame.contains(p) }) {
                targetScreen = s
            }

            let full = targetScreen.frame
            let vis = targetScreen.visibleFrame
            targetOnLeft = p.x < full.midX

            let pillH = DeckGeom.pillHeight(noteCount: max(1, NoteStore.shared.active.count))
            let availableH = max(1, vis.height - pillH)
            let rawY = p.y - pillH / 2
            let clampedY = min(max(vis.minY, rawY), vis.maxY - pillH)
            targetYRatio = (clampedY - vis.minY) / availableH

            let w = max(DeckGeom.pillWidth + 2, CGFloat(Settings.edgeWidth))
            let liveFrame = NSRect(x: targetOnLeft ? full.minX : full.maxX - w,
                                   y: round(clampedY),
                                   width: w,
                                   height: pillH)
            panel.setFrame(liveFrame, display: true, animate: false)
        }

        Settings.deckOnLeftEdge = targetOnLeft
        Settings.deckYRatio = targetYRatio
        // Only follow the drag across displays when the deck is already pinned to
        // one. Doing it under "All Displays" would take the deck off every other
        // screen as a side effect of nudging the pill up a bit.
        if Settings.displayTarget != "all",
           let id = (targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value {
            Settings.displayTarget = "id:\(id)"
        }
        (NSApp.delegate as? AppDelegate)?.refreshDecks()
    }

    /// The panel is wide enough to hold an open note, but the deck itself only
    /// occupies the strip against the screen edge — that strip is what "leaving
    /// the deck" means.
    private var hotZone: NSRect {
        let f = panel.frame
        let w = DeckGeom.fanWidth + 20
        return Settings.deckOnLeftEdge
            ? NSRect(x: f.minX, y: f.minY, width: w, height: f.height)
            : NSRect(x: f.maxX - w, y: f.minY, width: w, height: f.height)
    }

    func pointerExited() {
        guard model.state == .fan, restingState != .fan else { return }   // an open note stays open until Esc
        // Tracking areas fire spuriously across a resize, so confirm the pointer really left.
        exitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.state == .fan, !self.model.isDragging else { return }
            if !self.hotZone.contains(NSEvent.mouseLocation) {
                DeckLog.line("pointerExited confirmed")
                self.setState(self.restingState)
            }
        }
        exitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func expand(_ id: String) {
        noteActivity()
        model.openedHeight = Settings.noteSize.height
        model.openedTop = nil
        manager?.deckDidActivate(self)
        setState(.expanded(id))
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Closing a note steps back to the deck — the tabs stay where they were.
    /// Only leaving the deck entirely puts it back to sleep.
    func collapse() {
        model.openedTop = nil
        if model.state.expandedID != nil {
            setState(.fan)
            NSApp.deactivate()
            // If the pointer is already away from the edge, the deck follows it
            // shut on the next poll rather than hanging around.
        } else {
            setState(restingState)
        }
    }

    /// True while the open note is pinned — it should survive anything the user
    /// did not aim at it.
    private var openNoteIsPinned: Bool {
        guard let id = model.state.expandedID else { return false }
        return NoteStore.shared.note(id: id)?.pinned ?? false
    }

    /// Dismiss the whole deck, note and tabs together.
    func dismiss() {
        let wasExpanded = model.state.expandedID != nil
        setState(restingState)
        if wasExpanded { NSApp.deactivate() }
    }

    func collapseToRest() { setState(restingState) }

    /// Adopt a change to the preference: fan out, or fall back to the pill once
    /// the pointer is off the deck. Called after Settings writes it.
    func applyRestingState() {
        switch model.state {
        case .rest where restingState == .fan:
            setState(.fan)
        case .fan where restingState == .rest:
            // The pointer may still be on the deck, and yanking the tabs out from
            // under it reads as a glitch. Restart the idle poll instead and let it
            // fold the deck away the moment the pointer leaves — without this the
            // fan stays stuck open, because the poll is not running while the deck
            // is at its resting state.
            if hotZone.contains(NSEvent.mouseLocation) { startIdleWatch() }
            else { setState(.rest) }
        default:
            break
        }
    }

    // MARK: Key handling for the expanded note

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let id = self.model.state.expandedID,
                  self.panel.isKeyWindow else { return event }
            self.noteActivity()

            // Close first: while the find bar is up it takes the key instead.
            if Settings.scClose.matches(event) {
                if self.model.findQuery != nil { self.model.findQuery = nil }
                else { self.collapse() }
                return nil
            }
            if Settings.scArchiveNote.matches(event) {
                NoteStore.shared.setArchived(id: id, true); self.collapse(); return nil
            }
            if Settings.scDelete.matches(event) {
                NoteStore.shared.delete(id: id); self.collapse(); return nil
            }
            if Settings.scFind.matches(event) {
                self.model.findQuery = self.model.findQuery == nil ? "" : nil; return nil
            }
            if Settings.scTask.matches(event) {
                self.model.bridge.toggleTaskLine(); return nil
            }
            if Settings.scPin.matches(event) {
                NoteStore.shared.togglePin(id: id); return nil
            }
            if Settings.scColour.matches(event) {
                NoteStore.shared.cycleColor(id: id); return nil
            }
            if Settings.scBigger.matches(event) {
                (NSApp.delegate as? AppDelegate)?.stepFontSize(by: 1.5); return nil
            }
            if Settings.scSmaller.matches(event) {
                (NSApp.delegate as? AppDelegate)?.stepFontSize(by: -1.5); return nil
            }
            return event
        }
    }

    /// A click in any other app dismisses the open note. Mouse-only global
    /// monitors need no Accessibility permission.
    private func installOutsideMonitor() {
        guard outsideMonitor == nil else { return }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.model.state.expandedID != nil,
                  !self.openNoteIsPinned else { return }
            DispatchQueue.main.async { self.dismiss() }
        }
    }

    private func removeOutsideMonitor() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        outsideMonitor = nil
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: Context menu

    func showContextMenu(at event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Note", action: #selector(AppDelegate.newNote), keyEquivalent: "")
        menu.addItem(withTitle: "All Notes", action: #selector(AppDelegate.openAllNotes), keyEquivalent: "")
        menu.addItem(withTitle: "Archive", action: #selector(AppDelegate.openArchive), keyEquivalent: "")
        menu.addItem(.separator())

        let overFS = NSMenuItem(title: "Show over full-screen apps",
                                action: #selector(AppDelegate.toggleOverFullScreen), keyEquivalent: "")
        overFS.state = Settings.showOverFullScreen ? .on : .off
        menu.addItem(overFS)

        let styleItem = NSMenuItem(title: "Deck style", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        for s in DeckStyle.allCases {
            let it = NSMenuItem(title: s.title, action: #selector(AppDelegate.setDeckStyle(_:)), keyEquivalent: "")
            it.representedObject = s.rawValue
            it.state = Settings.deckStyle == s ? .on : .off
            styleMenu.addItem(it)
        }
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        let fontItem = NSMenuItem(title: "Note font", action: nil, keyEquivalent: "")
        let fontMenu = NSMenu()
        for f in Ink.faces {
            let it = NSMenuItem(title: f.name, action: #selector(AppDelegate.setNoteFont(_:)),
                                keyEquivalent: "")
            it.representedObject = f.body
            it.state = Ink.face.body == f.body ? .on : .off
            fontMenu.addItem(it)
        }
        fontItem.submenu = fontMenu
        menu.addItem(fontItem)

        let textItem = NSMenuItem(title: "Text size", action: nil, keyEquivalent: "")
        let textMenu = NSMenu()
        for entry in Settings.fontSizes {
            let it = NSMenuItem(title: entry.name, action: #selector(AppDelegate.setFontSize(_:)),
                                keyEquivalent: "")
            it.representedObject = entry.size
            it.state = abs(Settings.noteFontSize - entry.size) < 0.01 ? .on : .off
            textMenu.addItem(it)
        }
        textItem.submenu = textMenu
        menu.addItem(textItem)

        let sizeItem = NSMenuItem(title: "Deck size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for entry in Settings.deckSizes {
            let it = NSMenuItem(title: entry.name, action: #selector(AppDelegate.setDeckScale(_:)),
                                keyEquivalent: "")
            it.representedObject = entry.scale
            it.state = abs(Settings.deckScale - entry.scale) < 0.01 ? .on : .off
            sizeMenu.addItem(it)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let keepOpen = NSMenuItem(title: "Keep deck open",
                                  action: #selector(AppDelegate.toggleDeckAlwaysShown), keyEquivalent: "")
        keepOpen.state = Settings.deckAlwaysShown ? .on : .off
        menu.addItem(keepOpen)

        let leftEdge = NSMenuItem(title: "Dock deck to left edge",
                                  action: #selector(AppDelegate.toggleDeckEdge), keyEquivalent: "")
        leftEdge.state = Settings.deckOnLeftEdge ? .on : .off
        menu.addItem(leftEdge)

        if NSScreen.screens.count > 1 {
            let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
            let displayMenu = NSMenu()

            let allItem = NSMenuItem(title: "All Displays", action: #selector(AppDelegate.setDisplayTarget(_:)), keyEquivalent: "")
            allItem.representedObject = "all"
            allItem.state = Settings.displayTarget == "all" ? .on : .off
            displayMenu.addItem(allItem)

            let mainItem = NSMenuItem(title: "Main Display", action: #selector(AppDelegate.setDisplayTarget(_:)), keyEquivalent: "")
            mainItem.representedObject = "main"
            mainItem.state = Settings.displayTarget == "main" ? .on : .off
            displayMenu.addItem(mainItem)

            displayMenu.addItem(.separator())

            for screen in NSScreen.screens {
                guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { continue }
                let name = screen.localizedName
                let title = screen == NSScreen.main ? "\(name) (Main)" : name
                let it = NSMenuItem(title: title, action: #selector(AppDelegate.setDisplayTarget(_:)), keyEquivalent: "")
                it.representedObject = "id:\(id)"
                it.state = Settings.displayTarget == "id:\(id)" ? .on : .off
                displayMenu.addItem(it)
            }
            displayItem.submenu = displayMenu
            menu.addItem(displayItem)
        }

        let updates = NSMenuItem(title: "Check for Updates…",
                                 action: #selector(AppDelegate.checkForUpdates), keyEquivalent: "")
        menu.addItem(updates)

        let autoUpdate = NSMenuItem(title: "Check automatically",
                                    action: #selector(AppDelegate.toggleAutoUpdates), keyEquivalent: "")
        autoUpdate.state = Updater.shared.automaticallyChecks ? .on : .off
        autoUpdate.isEnabled = Updater.available
        menu.addItem(autoUpdate)
        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at login",
                               action: #selector(AppDelegate.toggleLaunchAtLogin), keyEquivalent: "")
        login.state = Settings.launchAtLogin ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        let exportItem = NSMenuItem(title: "Export", action: nil, keyEquivalent: "")
        let exportMenu = NSMenu()
        exportMenu.addItem(withTitle: "Markdown (one file per note)…",
                           action: #selector(AppDelegate.exportMarkdown), keyEquivalent: "")
        exportMenu.addItem(withTitle: "Plain text (one file per note)…",
                           action: #selector(AppDelegate.exportPlainText), keyEquivalent: "")
        exportMenu.addItem(withTitle: "Single document…",
                           action: #selector(AppDelegate.exportSingleFile), keyEquivalent: "")
        exportMenu.addItem(withTitle: "Sticky archive (.stickies)…",
                           action: #selector(AppDelegate.exportStickies), keyEquivalent: "")
        exportItem.submenu = exportMenu
        menu.addItem(exportItem)
        menu.addItem(withTitle: "Import…", action: #selector(AppDelegate.importStickies), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.openSettings), keyEquivalent: "")
        menu.addItem(withTitle: "Quit Noty", action: #selector(AppDelegate.quit), keyEquivalent: "")

        for item in menu.items where item.action != nil {
            item.target = NSApp.delegate
        }
        NSMenu.popUpContextMenu(menu, with: event, for: container)
    }
}

// MARK: - Manager

/// Keeps one deck alive per targeted display and rebuilds the set when displays or settings change.
final class DeckManager {
    private(set) var decks: [CGDirectDisplayID: DeckController] = [:]

    init() {
        rebuild()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
    }

    private func targetDisplayIDs() -> Set<CGDirectDisplayID> {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return [] }

        let screenMap: [CGDirectDisplayID: NSScreen] = Dictionary(uniqueKeysWithValues: screens.compactMap { s in
            guard let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return (id, s)
        })

        let mainID: CGDirectDisplayID = {
            if let main = NSScreen.main,
               let id = (main.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value {
                return id
            }
            return screenMap.keys.first ?? CGMainDisplayID()
        }()

        let target = Settings.displayTarget
        if target == "all" {
            return Set(screenMap.keys)
        } else if target == "main" {
            return [mainID]
        } else if target.hasPrefix("id:"), let id = UInt32(target.dropFirst(3)) {
            if screenMap.keys.contains(id) {
                return [id]
            } else {
                return [mainID]
            }
        }
        return Set(screenMap.keys)
    }

    func rebuild() {
        let targetIDs = targetDisplayIDs()
        for id in Array(decks.keys) where !targetIDs.contains(id) {
            decks.removeValue(forKey: id)
        }
        for id in targetIDs where decks[id] == nil {
            let d = DeckController(displayID: id)
            d.manager = self
            decks[id] = d
        }
        decks.values.forEach { $0.layout() }
    }

    /// Only one deck is open at a time — the one the pointer entered.
    func deckDidActivate(_ active: DeckController) {
        for d in decks.values where d !== active { d.collapseToRest() }
    }

    func refreshAll() {
        rebuild()
        decks.values.forEach {
            $0.model.syncPreferences(); $0.refreshLevel(); $0.layout(); $0.applyRestingState()
        }
    }

    /// Deck on the screen holding the pointer, else the first available deck.
    var focused: DeckController? {
        let p = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { $0.frame.contains(p) }),
           let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
           let deck = decks[id] {
            return deck
        }
        return decks.values.first
    }
}
