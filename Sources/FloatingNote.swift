import AppKit
import SwiftUI
import Combine

final class NoteWindowState: ObservableObject {
    @Published var maximized = false
    @Published var fullScreen = false
    @Published var transitioning = false
}

/// One independently movable note. Floating notes remain open until explicitly
/// closed or moved to Trash, so a workspace does not disappear while reading.
final class FloatingNote: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?

    private(set) var noteID: String?
    private var panel: FloatingPanel?
    let windowState = NoteWindowState()
    private var restoreFrame: NSRect?
    private var closeAfterTransition = false
    private var storeObserver: AnyCancellable?
    private var keyMonitor: Any?

    var isShowing: Bool { noteID != nil }

    // MARK: Presenting

    /// Called mid-drag, the moment the note crosses the detach threshold. The
    /// panel appears under the pointer and `dragTo` steers it until mouse-up.
    func present(id: String, under pointer: NSPoint, grabOffset: NSPoint) {
        guard noteID == nil else { focus(); return }

        let size = Settings.floatingNoteSize
        // A titled NSWindow supports native full-screen Spaces and tiling.
        // Each controller retains its own editor and restore geometry.
        let p = FloatingPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        p.noteController = self
        p.tabbingMode = .disallowed
        p.minSize = NSSize(width: 280, height: 220)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.title = NoteStore.shared.note(id: id)?.displayTitle ?? "Noty"
        p.level = .floating
        p.collectionBehavior = normalCollectionBehavior
        p.isReleasedWhenClosed = false
        p.delegate = self
        p.contentView = NSHostingView(rootView: FloatingNoteView(
            noteID: id,
            windowState: windowState,
            onMaximize: { [weak self] in self?.toggleMaximize() },
            onFullScreen: { [weak self] in self?.toggleFullScreen() },
            onClose: { [weak self] in self?.tuck() }))
        p.contentView?.layoutSubtreeIfNeeded()

        noteID = id
        panel = p
        self.grabOffset = grabOffset
        dragTo(pointer)
        p.orderFrontRegardless()
        startWatching()
    }

    // MARK: Resizing

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel, !windowState.fullScreen, !windowState.transitioning else { return }
        restoreFrame = nil
        windowState.maximized = false
        Settings.floatingNoteSize = panel.contentRect(forFrameRect: panel.frame).size
    }

    private var normalCollectionBehavior: NSWindow.CollectionBehavior {
        Settings.confineToSpace ? [.fullScreenPrimary] : [.canJoinAllSpaces, .fullScreenPrimary]
    }

    func toggleMaximize() {
        guard let panel, !windowState.fullScreen, !windowState.transitioning,
              let screen = panel.screen ?? NSScreen.main else { return }
        if let restoreFrame {
            // Keep a restored note reachable if a display was disconnected.
            var frame = restoreFrame
            let visible = screen.visibleFrame
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
            panel.setFrame(frame, display: true)
            self.restoreFrame = nil
            windowState.maximized = false
        } else {
            restoreFrame = panel.frame
            windowState.maximized = true
            panel.setFrame(screen.visibleFrame, display: true)
        }
        focus()
    }

    func enterFullScreen() {
        guard !windowState.fullScreen, !windowState.transitioning else { focus(); return }
        toggleFullScreen()
    }

    func toggleFullScreen() {
        guard let panel, !windowState.transitioning else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        windowState.transitioning = true
        panel.level = .normal
        panel.collectionBehavior = [.fullScreenPrimary]
        panel.toggleNativeFullScreen()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        windowState.transitioning = true
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        windowState.fullScreen = true
        finishFullScreenTransition()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        windowState.transitioning = true
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        windowState.fullScreen = false
        finishFullScreenTransition()
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        windowState.fullScreen = false
        finishFullScreenTransition()
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        windowState.fullScreen = true
        closeAfterTransition = false
        finishFullScreenTransition()
    }

    private func finishFullScreenTransition() {
        windowState.transitioning = false
        if !windowState.fullScreen { panel?.collectionBehavior = normalCollectionBehavior }
        applyLevel()
        if closeAfterTransition { closeAfterTransition = false; tuck(animated: false) }
    }

    /// Where inside the note the user grabbed it, so the paper does not jump
    /// under the cursor when the panel takes over from the deck.
    private var grabOffset = NSPoint.zero

    func dragTo(_ pointer: NSPoint) {
        guard let panel else { return }
        panel.setFrameOrigin(NSPoint(x: pointer.x - grabOffset.x,
                                     y: pointer.y - grabOffset.y))
    }

    /// Mouse released: the note now lives here. Take key so typing just works.
    func endDrag(cancelled: Bool) {
        if cancelled { tuck(animated: false); return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        applyLevel()
        panel?.makeKeyAndOrderFront(nil)
    }

    /// The pin decides the altitude. Unpinned, the note is an ordinary window —
    /// covered when you work elsewhere, raised when you click it. Pinned, it
    /// stays above everything, the way a sticky stuck to the bezel would.
    /// During the pull itself the panel stays at .floating regardless, so it
    /// cannot slide underneath the deck's own panel mid-drag.
    func applyLevel() {
        guard let panel, let id = noteID else { return }
        let pinned = NoteStore.shared.note(id: id)?.pinned ?? false
        let level: NSWindow.Level = pinned && !windowState.fullScreen && !windowState.transitioning ? .floating : .normal
        if panel.level != level { panel.level = level }
    }

    /// Clicking the note's tab on the deck lands here. The note may be an
    /// unpinned normal-level window buried under the active app, and a plain
    /// makeKey only fronts it within Noty — orderFrontRegardless is what lifts
    /// it above the app you are actually in.
    func focus() {
        guard let panel else {
            NSLog("Noty: focus — no floating panel")
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        if windowState.fullScreen || windowState.transitioning {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        // Front-of-level for a background app's normal-level window is the
        // flaky corner of AppKit ordering. Lift at floating level so the raise
        // is unambiguous, then settle back to whatever the pin says once the
        // window is up — a click elsewhere can cover an unpinned note again.
        panel.level = .floating
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.applyLevel()
        }
    }

    // MARK: Tucking back

    /// Slide home to the deck's edge and disappear — the note is still one
    /// hover away in the deck, exactly as if it had been closed there.
    func tuck(animated: Bool = true) {
        guard let panel else { return }
        if windowState.transitioning { closeAfterTransition = true; return }
        if windowState.fullScreen {
            closeAfterTransition = true
            toggleFullScreen()
            return
        }
        stopWatching()
        if let id = noteID { NoteStore.shared.flush(id: id) }
        noteID = nil
        self.panel = nil
        panel.delegate = nil
        onClose?()

        let finish = {
            panel.close()
            panel.contentView = nil
            AppWindows.didClose(Notification(name: NSWindow.willCloseNotification, object: panel))
        }
        guard animated, let screen = panel.screen ?? NSScreen.main else { finish(); return }
        let onRight = !Settings.deckOnLeftEdge
        var target = panel.frame
        target.origin.x = onRight ? screen.frame.maxX - 8 : screen.frame.minX - target.width + 8
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            finish()
            panel.alphaValue = 1
        })
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        tuck(animated: false)
        return false
    }

    // MARK: Store and keyboard observation

    private func startWatching() {
        stopWatching()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isKeyWindow else { return event }
            let plainEscape = event.keyCode == 53 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            if plainEscape && (self.windowState.fullScreen || self.windowState.transitioning) {
                // Let the input method cancel its marked text first.
                if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
                if !self.windowState.transitioning { self.toggleFullScreen() }
                return nil
            }
            if Settings.scClose.matches(event) { self.tuck(); return nil }
            return event
        }
        storeObserver = NoteStore.shared.$notes.receive(on: RunLoop.main).sink { [weak self] notes in
            guard let self, let id = self.noteID else { return }
            guard let note = notes.first(where: { $0.id == id }), !note.isTrashed else {
                self.tuck(animated: false); return
            }
            self.panel?.title = note.displayTitle
            self.applyLevel()
        }
    }

    private func stopWatching() {
        storeObserver = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

}

/// Route native zoom and full-screen controls through the same per-note state.
private final class FloatingPanel: NSWindow {
    weak var noteController: FloatingNote?
    override func zoom(_ sender: Any?) { noteController?.toggleMaximize() }
    override func toggleFullScreen(_ sender: Any?) { noteController?.toggleFullScreen() }
    func toggleNativeFullScreen() { super.toggleFullScreen(nil) }
}

/// The note's paper, free of the deck. Same editor, same autosave; the header
/// doubles as the drag handle.
private struct FloatingNoteView: View {
    let noteID: String
    @ObservedObject var windowState: NoteWindowState
    let onMaximize: () -> Void
    let onFullScreen: () -> Void
    let onClose: () -> Void

    @ObservedObject private var store = NoteStore.shared
    @StateObject private var bridge = EditorBridge()
    private var textBinding: Binding<String> {
        Binding(get: { store.note(id: noteID)?.body ?? "" }, set: {
            store.updateBody(id: noteID, body: $0)
        })
    }

    private var note: Note? { store.note(id: noteID) }

    var body: some View {
        if let note {
            let pal = note.palette
            VStack(spacing: 0) {
                header(note, pal)
                NoteFormattingBar(bridge: bridge, foreground: pal.ink.opacity(0.8))
                NoteTextView(text: textBinding, ink: NSColor(pal.ink),
                             bridge: bridge, autofocus: false,
                             fontSize: Settings.noteFontSize,
                             markdownEnabled: Settings.markdownStyling,
                             textDirection: note.textDirection,
                             styleToken: "\(note.color)|\(Settings.noteFontSize)|\(Settings.noteFontName)|\(Settings.markdownStyling)")
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [pal.paper, pal.paper.opacity(0.88)],
                                         startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.30), radius: 16, y: 5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(pal.ink.opacity(0.14), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onDisappear { flush() }
        }
    }

    private func header(_ note: Note, _ pal: NoteColor) -> some View {
        HStack(spacing: 8) {
            Circle().fill(pal.dash).frame(width: 8, height: 8)
            Text(note.displayTitle)
                .font(Ink.bodyFont(12.5).weight(.semibold))
                .foregroundStyle(pal.ink.opacity(0.92))
                .lineLimit(1)
            Spacer(minLength: 6)
            Button(action: onMaximize) {
                Image(systemName: windowState.maximized ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(L10n.text(windowState.maximized ? "note.restore_size" : "note.maximize"))
            .accessibilityLabel(L10n.text(windowState.maximized ? "note.restore_size" : "note.maximize"))
            .disabled(windowState.fullScreen || windowState.transitioning)
            Button(action: onFullScreen) {
                Image(systemName: windowState.fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(L10n.text(windowState.fullScreen ? "note.exit_full_screen" : "note.full_screen"))
            .accessibilityLabel(L10n.text(windowState.fullScreen ? "note.exit_full_screen" : "note.full_screen"))
            .disabled(windowState.transitioning)
            Button {
                NoteStore.shared.togglePin(id: note.id)
                FloatingNotes.shared.applyLevels()
            } label: {
                Image(systemName: note.pinned ? "pin.fill" : "pin")
                    .font(Ink.bodyFont(11).weight(.semibold))
                    .rotationEffect(.degrees(note.pinned ? 0 : 32))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(pal.ink.opacity(note.pinned ? 0.85 : 0.4))
            .help(note.pinned ? L10n.text("help.unpin") : L10n.text("help.pin"))
            Button { flush(); onClose() } label: {
                Image(systemName: "xmark")
                    .font(Ink.bodyFont(10).weight(.bold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(pal.ink.opacity(0.45))
            .help(L10n.text("action.close"))
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .foregroundStyle(pal.ink.opacity(0.8))
        .contentShape(Rectangle())
        // The header is the handle: NSWindow does the dragging natively, which
        // keeps it smooth and lets it cross displays for free.
        .gesture(WindowDragGesture())
    }

    private func flush() { store.flush(id: noteID) }
}
