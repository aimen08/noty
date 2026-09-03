import AppKit
import SwiftUI
import Carbon.HIToolbox

/// A small floating input summoned from anywhere: type, hit ↩, and the text
/// becomes a note in the deck — no editor opened, no focus ceremony. The whole
/// point is that it costs nothing to jot something down mid-task.
final class QuickCapture: NSObject, NSWindowDelegate {
    static let shared = QuickCapture()
    private var panel: NSPanel?
    private var shownAt = Date.distantPast

    func toggle() {
        // Carbon delivers a fresh hot-key event for every autorepeat while the
        // combo is held, and a toggle per repeat flaps the box open and shut.
        // Anything inside the repeat window is the same press.
        guard Date().timeIntervalSince(shownAt) > 0.35 else { return }
        // Stamp on every accepted toggle, not only in show(): a hold-to-close
        // otherwise dismisses on the first event and reopens on its autorepeat.
        shownAt = Date()
        if panel != nil { dismiss() } else { show() }
    }

    func show() {
        guard panel == nil else {
            panel?.makeKeyAndOrderFront(nil)
            return
        }
        let p = CapturePanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 150),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.delegate = self
        p.contentView = NSHostingView(rootView: CaptureView(
            onSave: { [weak self] text, target in self?.save(text, into: target) },
            onCancel: { [weak self] in self?.dismiss() }))

        // On the screen the pointer is on, a little above centre — where the eye
        // already is, without covering what is being worked on.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let vis = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: vis.midX - 230,
                                     y: vis.minY + vis.height * 0.58))
        }
        panel = p
        shownAt = Date()
        // Deliberately no NSApp.activate(): a non-activating panel can take key
        // input while the app in front stays active. Activating steals focus —
        // the front window dims, its focus rings drop, and it all snaps back on
        // dismiss, which reads as UI flashing behind the box.
        p.contentView?.layoutSubtreeIfNeeded()
        p.makeKeyAndOrderFront(nil)
    }

    private func save(_ text: String, into targetID: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            // Append to the chosen note — or a fresh one when none was picked,
            // or the picked one was deleted while the box sat open.
            if let targetID, let note = NoteStore.shared.note(id: targetID) {
                let body = note.body.isEmpty ? trimmed : note.body + "\n" + trimmed
                NoteStore.shared.updateBody(id: targetID, body: body)
            } else {
                _ = NoteStore.shared.create(body: trimmed)
            }
        }
        dismiss()
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Clicking anywhere else is a cancel — a capture box that lingers is
    /// clutter. But key status can bounce for an instant right after the panel
    /// opens while the hot-key's own release is still being processed by the
    /// app in front; inside that window, take key back instead of dying.
    func windowDidResignKey(_ notification: Notification) {
        if Date().timeIntervalSince(shownAt) < 0.35 {
            panel?.makeKeyAndOrderFront(nil)
        } else {
            dismiss()
        }
    }
}

/// Borderless panels refuse key status by default, and a capture box that
/// cannot be typed into is nothing at all.
private final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct CaptureView: View {
    let onSave: (String, String?) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    /// nil — a new note. Otherwise the captured text is appended to this one,
    /// which is what issue #26 asked for: jot into an existing tab, not a pile
    /// of new ones.
    @State private var targetID: String?
    @FocusState private var focused: Bool

    private var targets: [Note] { Array(NoteStore.shared.active.prefix(8)) }

    /// The paper previews the destination: the chosen note's colour, or the
    /// colour a new note would get.
    private var pal: NoteColor {
        if let targetID, let n = NoteStore.shared.note(id: targetID) { return n.palette }
        return NoteColor.at(NoteStore.shared.notes.count % NoteColor.all.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle().fill(pal.dash).frame(width: 8, height: 8)
                // The label names the destination: the chosen note, or a fresh
                // quick note. One glance answers "where will this land".
                Text(targetID.flatMap { NoteStore.shared.note(id: $0)?.displayTitle }
                     ?? L10n.text("capture.title"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(pal.ink.opacity(0.55))
                    .lineLimit(1)
                Spacer(minLength: 10)
                // Destinations as colour dots — the deck's own vocabulary. The
                // ring marks the choice; hovering names it.
                HStack(spacing: 6) {
                    dot(nil)
                    ForEach(targets) { note in dot(note.id) }
                }
            }

            TextEditor(text: $text)
                .font(Ink.body(13.5).swiftUIFont)
                .foregroundStyle(pal.ink)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .frame(height: 72)
                .onKeyPress(.return, phases: .down) { press in
                    // ↩ saves; ⇧↩ falls through to the editor as a newline.
                    guard !press.modifiers.contains(.shift) else { return .ignored }
                    onSave(text, targetID)
                    return .handled
                }
                .onKeyPress(.escape) { onCancel(); return .handled }
                // ⌘1 keeps a fresh note; ⌘2… aim at an existing tab.
                .onKeyPress(phases: .down) { press in
                    guard press.modifiers.contains(.command),
                          let digit = press.characters.first?.wholeNumberValue,
                          (1...targets.count + 1).contains(digit) else { return .ignored }
                    targetID = digit == 1 ? nil : targets[digit - 2].id
                    return .handled
                }

            Text(L10n.text("capture.hint"))
                .font(.system(size: 10))
                .foregroundStyle(pal.ink.opacity(0.4))
        }
        .padding(14)
        .frame(width: 460, height: 150)
        .animation(.easeInOut(duration: 0.15), value: targetID)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(pal.paper)
                .shadow(color: .black.opacity(0.28), radius: 14, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(pal.ink.opacity(0.14), lineWidth: 1)
        )
        .onAppear { focused = true }
    }

    private func dot(_ id: String?) -> some View {
        let selected = targetID == id
        let colour = id.flatMap { NoteStore.shared.note(id: $0)?.palette.dash }
        return Button {
            targetID = id
        } label: {
            ZStack {
                if let colour {
                    Circle().fill(colour)
                } else {
                    // A fresh note: an empty ring with a plus, not yet any colour.
                    Circle().strokeBorder(pal.ink.opacity(0.45), lineWidth: 1.2)
                    Image(systemName: "plus")
                        .font(.system(size: 5.5, weight: .bold))
                        .foregroundStyle(pal.ink.opacity(0.6))
                }
            }
            .frame(width: 10, height: 10)
            .overlay(
                Circle().strokeBorder(pal.ink.opacity(selected ? 0.75 : 0), lineWidth: 1.3)
                    .padding(-3)
            )
            .scaleEffect(selected ? 1.15 : 1)
            .contentShape(Circle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .help(id.flatMap { NoteStore.shared.note(id: $0)?.displayTitle } ?? L10n.text("note.untitled"))
    }
}

private extension NSFont {
    /// TextEditor wants a SwiftUI Font; the note face is stored as an NSFont.
    var swiftUIFont: Font { Font(self as CTFont) }
}
