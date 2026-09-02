import AppKit
import SwiftUI

/// A note pulled off the deck and left wherever it was dropped. It keeps the
/// deck's manners: idle too long and it tucks itself back to the screen edge —
/// unless it is pinned, in which case it stays put like any good sticky.
/// One at a time, matching the deck's one-open-note model; pulling a second
/// note out tucks the first.
final class FloatingNote: NSObject, NSWindowDelegate {
    static let shared = FloatingNote()

    private(set) var noteID: String?
    private var panel: NSPanel?
    private var idleTimer: Timer?
    private var lastActivity = Date()
    private var keyMonitor: Any?

    var isShowing: Bool { noteID != nil }

    // MARK: Presenting

    /// Called mid-drag, the moment the note crosses the detach threshold. The
    /// panel appears under the pointer and `dragTo` steers it until mouse-up.
    func present(id: String, under pointer: NSPoint, grabOffset: NSPoint) {
        if noteID != nil { tuck(animated: false) }

        let size = Settings.floatingNoteSize
        // .resizable on a borderless window is what turns every edge and
        // corner into a native live-resize band, system cursors included —
        // no hand-rolled drag handles, and no relayout jank from driving the
        // frame ourselves.
        let p = FloatingPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless, .nonactivatingPanel, .resizable],
                              backing: .buffered, defer: false)
        p.minSize = NSSize(width: 280, height: 220)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.delegate = self
        p.contentView = NSHostingView(rootView: FloatingNoteView(
            noteID: id,
            onActivity: { [weak self] in self?.lastActivity = Date() },
            onClose: { [weak self] in self?.tuck() }))
        p.contentView?.layoutSubtreeIfNeeded()

        noteID = id
        panel = p
        self.grabOffset = grabOffset
        dragTo(pointer)
        p.orderFrontRegardless()
        startIdleWatch()
    }

    // MARK: Resizing

    /// Live resize counts as activity — a note must never tuck away mid-grab.
    func windowDidResize(_ notification: Notification) { lastActivity = Date() }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel else { return }
        Settings.floatingNoteSize = panel.frame.size
    }

    /// Where inside the note the user grabbed it, so the paper does not jump
    /// under the cursor when the panel takes over from the deck.
    private var grabOffset = NSPoint.zero

    func dragTo(_ pointer: NSPoint) {
        guard let panel else { return }
        lastActivity = Date()
        panel.setFrameOrigin(NSPoint(x: pointer.x - grabOffset.x,
                                     y: pointer.y - grabOffset.y))
    }

    /// Mouse released: the note now lives here. Take key so typing just works.
    func endDrag(cancelled: Bool) {
        if cancelled { tuck(animated: false); return }
        lastActivity = Date()
        panel?.makeKeyAndOrderFront(nil)
    }

    func focus() {
        lastActivity = Date()
        panel?.makeKeyAndOrderFront(nil)
    }

    // MARK: Tucking back

    /// Slide home to the deck's edge and disappear — the note is still one
    /// hover away in the deck, exactly as if it had been closed there.
    func tuck(animated: Bool = true) {
        guard let panel else { return }
        stopIdleWatch()
        let id = noteID
        noteID = nil
        self.panel = nil

        let finish = {
            panel.orderOut(nil)
            panel.contentView = nil
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
        _ = id
    }

    // MARK: Idle

    private func startIdleWatch() {
        stopIdleWatch()
        lastActivity = Date()
        // Esc tucks the note from anywhere inside it, matching the deck.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isKeyWindow else { return event }
            self.lastActivity = Date()
            if event.keyCode == 53 { self.tuck(); return nil }
            return event
        }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, let panel = self.panel, let id = self.noteID else { return }
            // A note deleted or archived elsewhere has nothing left to float.
            guard let note = NoteStore.shared.note(id: id), !note.archived else {
                self.tuck(animated: false); return
            }
            if note.pinned || panel.isKeyWindow
                || panel.frame.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation) {
                self.lastActivity = Date()
                return
            }
            if Date().timeIntervalSince(self.lastActivity) > Settings.noteIdleTimeout {
                self.tuck()
            }
        }
    }

    private func stopIdleWatch() {
        idleTimer?.invalidate(); idleTimer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

/// Borderless panels refuse key status by default; a note that cannot be typed
/// into is a screenshot.
private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The note's paper, free of the deck. Same editor, same autosave; the header
/// doubles as the drag handle.
private struct FloatingNoteView: View {
    let noteID: String
    let onActivity: () -> Void
    let onClose: () -> Void

    @ObservedObject private var store = NoteStore.shared
    @StateObject private var bridge = EditorBridge()
    @State private var text = ""
    @State private var saveWork: DispatchWorkItem?

    private var note: Note? { store.note(id: noteID) }

    var body: some View {
        if let note {
            let pal = note.palette
            VStack(spacing: 0) {
                header(note, pal)
                NoteTextView(text: $text, ink: NSColor(pal.ink),
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
            .onAppear { text = note.body }
            .onChange(of: text) { _, value in
                onActivity()
                scheduleSave(value)
            }
            .onDisappear { flush() }
        }
    }

    private func header(_ note: Note, _ pal: NoteColor) -> some View {
        HStack(spacing: 8) {
            // Only the title strip drags the window. WindowDragGesture moves
            // the window under the cursor, so a release still lands inside
            // whatever button the grab started on — dragging by the pin was
            // pinning the note, and dragging by the ✕ would have closed it.
            HStack(spacing: 8) {
                Circle().fill(pal.dash).frame(width: 8, height: 8)
                Text(note.displayTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(pal.ink.opacity(0.92))
                    .lineLimit(1)
                Spacer(minLength: 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            Button { NoteStore.shared.togglePin(id: note.id) } label: {
                Image(systemName: note.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(note.pinned ? 0 : 32))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(pal.ink.opacity(note.pinned ? 0.85 : 0.4))
            .help(note.pinned ? L10n.text("help.unpin") : L10n.text("help.pin"))
            Button { flush(); onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(pal.ink.opacity(0.45))
            .help(L10n.text("action.close"))
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private func scheduleSave(_ value: String) {
        saveWork?.cancel()
        let work = DispatchWorkItem {
            NoteStore.shared.updateBody(id: noteID, body: value)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func flush() {
        saveWork?.cancel()
        if !text.isEmpty || note?.body.isEmpty == false {
            NoteStore.shared.updateBody(id: noteID, body: text)
        }
    }
}
