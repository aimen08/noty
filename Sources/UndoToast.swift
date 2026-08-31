import AppKit
import SwiftUI
import Combine

/// "⌘⌫ deletes it with ten seconds to undo." — a floating confirmation that
/// tracks NoteStore.pendingUndo.
final class UndoToast {
    static let shared = UndoToast()
    private var panel: NSPanel?
    private var bag = Set<AnyCancellable>()

    func start() {
        NoteStore.shared.$pendingUndo
            .receive(on: RunLoop.main)
            .sink { [weak self] pending in
                if let pending { self?.show(pending) } else { self?.hide() }
            }
            .store(in: &bag)
    }

    private func show(_ pending: NoteStore.PendingDelete) {
        hide()
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 268, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: UndoToastView(pending: pending))

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let vis = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: vis.midX - 134, y: vis.minY + 34))
        }
        p.orderFrontRegardless()
        panel = p
    }

    private func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct UndoToastView: View {
    let pending: NoteStore.PendingDelete
    @State private var remaining: Double = 10

    private let tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0, remaining / 10))
                    .stroke(pending.note.palette.dash, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text("Заметка удалена").font(.system(size: 12, weight: .medium))
                Text(pending.note.displayTitle)
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button("Отменить") { NoteStore.shared.undoDelete() }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .semibold))
        }
        .padding(.horizontal, 14)
        .frame(width: 268, height: 44)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 14, y: 4)
        )
        .onReceive(tick) { _ in
            remaining = max(0, pending.deadline.timeIntervalSinceNow)
        }
    }
}
