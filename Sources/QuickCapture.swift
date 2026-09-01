import AppKit
import SwiftUI
import Carbon.HIToolbox

/// A small floating input summoned from anywhere: type, hit ↩, and the text
/// becomes a note in the deck — no editor opened, no focus ceremony. The whole
/// point is that it costs nothing to jot something down mid-task.
final class QuickCapture: NSObject, NSWindowDelegate {
    static let shared = QuickCapture()
    private var panel: NSPanel?

    func toggle() {
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
            onSave: { [weak self] text in self?.save(text) },
            onCancel: { [weak self] in self?.dismiss() }))

        // On the screen the pointer is on, a little above centre — where the eye
        // already is, without covering what is being worked on.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let vis = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: vis.midX - 230,
                                     y: vis.minY + vis.height * 0.58))
        }
        panel = p
        // Deliberately no NSApp.activate(): a non-activating panel can take key
        // input while the app in front stays active. Activating steals focus —
        // the front window dims, its focus rings drop, and it all snaps back on
        // dismiss, which reads as UI flashing behind the box.
        p.contentView?.layoutSubtreeIfNeeded()
        p.makeKeyAndOrderFront(nil)
    }

    private func save(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            _ = NoteStore.shared.create(body: trimmed)
        }
        dismiss()
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Clicking anywhere else is a cancel — a capture box that lingers is clutter.
    func windowDidResignKey(_ notification: Notification) { dismiss() }
}

/// Borderless panels refuse key status by default, and a capture box that
/// cannot be typed into is nothing at all.
private final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct CaptureView: View {
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    /// The colour the new note will actually get, so the box previews its paper.
    private var pal: NoteColor { NoteColor.at(NoteStore.shared.notes.count % NoteColor.all.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle().fill(pal.dash).frame(width: 8, height: 8)
                Text("Quick note")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(pal.ink.opacity(0.55))
                Spacer()
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
                    onSave(text)
                    return .handled
                }
                .onKeyPress(.escape) { onCancel(); return .handled }

            Text("↩ save    ⇧↩ new line    esc cancel")
                .font(.system(size: 10))
                .foregroundStyle(pal.ink.opacity(0.4))
        }
        .padding(14)
        .frame(width: 460, height: 150)
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
}

private extension NSFont {
    /// TextEditor wants a SwiftUI Font; the note face is stored as an NSFont.
    var swiftUIFont: Font { Font(self as CTFont) }
}
