import AppKit

/// One controller per note. Opening or closing one never replaces another.
final class FloatingNotes {
    static let shared = FloatingNotes()
    private var windows: [String: FloatingNote] = [:]
    private var draggingID: String?
    var noteIDs: Set<String> { Set(windows.keys) }

    func contains(id: String) -> Bool { windows[id] != nil }
    func focus(id: String) { windows[id]?.focus() }
    func applyLevels() { windows.values.forEach { $0.applyLevel() } }

    func maximize(id: String) {
        open(ids: [id])
        windows[id]?.toggleMaximize()
    }

    func fullScreen(id: String) {
        open(ids: [id])
        windows[id]?.enterFullScreen()
    }

    func present(id: String, under point: NSPoint, grabOffset: NSPoint) {
        guard let note = NoteStore.shared.note(id: id), !note.isTrashed else { return }
        if let existing = windows[id] { existing.focus(); return }
        let controller = FloatingNote()
        controller.onClose = { [weak self] in self?.windows.removeValue(forKey: id) }
        windows[id] = controller
        draggingID = id
        controller.present(id: id, under: point, grabOffset: grabOffset)
    }

    func dragTo(_ point: NSPoint) {
        if let id = draggingID { windows[id]?.dragTo(point) }
    }

    func endDrag(cancelled: Bool) {
        if let id = draggingID { windows[id]?.endDrag(cancelled: cancelled) }
        draggingID = nil
    }

    func open(ids: [String]) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        for (index, id) in ids.enumerated() {
            if contains(id: id) { focus(id: id); continue }
            let offset = CGFloat((windows.count + index) % 8) * 28
            let size = Settings.floatingNoteSize
            let visible = screen.visibleFrame
            let point = NSPoint(x: max(visible.minX, min(visible.maxX - size.width, visible.midX - size.width / 2 + offset)),
                                y: max(visible.minY, min(visible.maxY - size.height, visible.midY - size.height / 2 - offset)))
            present(id: id, under: point, grabOffset: .zero)
            endDrag(cancelled: false)
        }
    }

    func close(id: String) { windows[id]?.tuck(animated: false) }
    func closeAll() { Array(windows.values).forEach { $0.tuck(animated: false) } }
}
