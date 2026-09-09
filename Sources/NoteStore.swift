import Foundation
import Combine
import AppKit

/// The shared text changes immediately; only SQLite writes are debounced.
/// Failed writes remain dirty and are retried before the app can quit.
final class NoteStore: ObservableObject {
    static let shared = NoteStore()

    @Published private(set) var notes: [Note] = []
    /// Set when a note is deleted, cleared after the 10 s undo window elapses.
    @Published var pendingUndo: PendingDelete?

    private let store: Store
    @Published private(set) var unsavedIDs = Set<String>()
    @Published private(set) var lastError: String?
    private var saveWork: [String: DispatchWorkItem] = [:]
    private var writable = true
    private let onError: (Error) -> Void
    private var undoTimer: Timer?

    struct PendingDelete: Equatable {
        let note: Note
        let deadline: Date
    }

    init(store: Store = Store(), seedWelcome: Bool = true,
         onError: @escaping (Error) -> Void = NoteStore.showError) {
        self.store = store
        self.onError = onError
        do {
            notes = try store.load()
            if notes.isEmpty && seedWelcome { seedWelcomeNote() }
        } catch {
            writable = false
            report(error)
        }
    }

    static func showError(_ error: Error) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = L10n.text("storage.error_title")
            alert.informativeText = error.localizedDescription + "\n\n" + L10n.text("storage.error_help")
            alert.alertStyle = .warning
            NSApp.activate()
            alert.runModal()
        }
    }

    private func report(_ error: Error) {
        let message = error.localizedDescription
        guard lastError != message else { return }
        lastError = message
        onError(error)
    }

    @discardableResult
    private func persist(_ note: Note) -> Bool {
        saveWork.removeValue(forKey: note.id)?.cancel()
        do {
            try store.upsert(note)
            unsavedIDs.remove(note.id)
            if unsavedIDs.isEmpty { lastError = nil }
            return true
        } catch {
            unsavedIDs.insert(note.id)
            report(error)
            return false
        }
    }

    private func scheduleSave(id: String) {
        unsavedIDs.insert(id)
        saveWork[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush(id: id) }
        saveWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Always saves the current shared value, never a window's older copy.
    @discardableResult
    func flush(id: String) -> Bool {
        guard unsavedIDs.contains(id), let note = note(id: id) else { return true }
        return persist(note)
    }

    @discardableResult
    func flushAll() -> Bool {
        for id in Array(unsavedIDs) { flush(id: id) }
        return unsavedIDs.isEmpty
    }

    // MARK: Derived collections

    var active: [Note] { notes.filter { !$0.archived }.sorted { $0.order < $1.order } }
    var archived: [Note] { notes.filter { $0.archived }.sorted { $0.modified > $1.modified } }

    func note(id: String) -> Note? { notes.first { $0.id == id } }

    // MARK: Mutations

    @discardableResult
    func create(body: String = "", title: String = "", color: Int? = nil) -> Note {
        var n = Note()
        n.order = (active.map(\.order).min() ?? 0) - 1   // newest sits at the top of the deck
        n.color = color ?? (notes.count % NoteColor.all.count)
        n.body = body
        n.title = title
        guard writable else { return n }
        notes.append(n)
        persist(n)
        return n
    }

    func updateTitle(id: String, title: String) {
        guard writable, let i = notes.firstIndex(where: { $0.id == id }) else { return }
        guard notes[i].title != title else { return }
        notes[i].title = title
        notes[i].modified = Date()
        scheduleSave(id: id)
    }

    func updateBody(id: String, body: String) {
        guard writable, let i = notes.firstIndex(where: { $0.id == id }) else { return }
        guard notes[i].body != body else { return }
        notes[i].body = body
        notes[i].modified = Date()
        scheduleSave(id: id)
    }

    func togglePin(id: String) {
        guard writable, let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].pinned.toggle()
        persist(notes[i])
    }

    func cycleColor(id: String) {
        guard writable, let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].color = (notes[i].color + 1) % NoteColor.all.count
        notes[i].modified = Date()
        persist(notes[i])
    }

    func setColor(id: String, color: Int) {
        guard writable, let i = notes.firstIndex(where: { $0.id == id }) else { return }
        guard NoteColor.all.indices.contains(color) else { return }
        notes[i].color = color
        notes[i].modified = Date()
        persist(notes[i])
    }

    func setTextDirection(id: String, direction: NoteTextDirection) {
        guard writable, let i = notes.firstIndex(where: { $0.id == id }),
              notes[i].textDirection != direction else { return }
        notes[i].textDirection = direction
        notes[i].modified = Date()
        persist(notes[i])
    }

    func setArchived(id: String, _ archived: Bool) {
        guard writable, let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].archived = archived
        notes[i].modified = Date()
        if !archived { notes[i].order = (active.map(\.order).min() ?? 0) - 1 }
        persist(notes[i])
    }

    /// Removes the note but keeps it recoverable for ten seconds.
    func delete(id: String) {
        guard writable, let i = notes.firstIndex(where: { $0.id == id }) else { return }
        let doomed = notes[i]
        do { try store.delete(id: id) }
        catch { report(error); return }
        saveWork.removeValue(forKey: id)?.cancel()
        unsavedIDs.remove(id)
        notes.remove(at: i)
        pendingUndo = PendingDelete(note: doomed, deadline: Date().addingTimeInterval(10))
        undoTimer?.invalidate()
        undoTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.pendingUndo = nil }
        }
    }

    func undoDelete() {
        guard writable, let p = pendingUndo else { return }
        undoTimer?.invalidate()
        notes.append(p.note)
        persist(p.note)
        pendingUndo = nil
    }

    /// Move a note `slots` positions up or down the deck, rewriting the order
    /// column densely so repeated drags cannot drift the values apart.
    func reorder(id: String, by slots: Int) {
        guard writable else { return }
        var list = active
        guard slots != 0, let from = list.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(0, from + slots), list.count - 1)
        guard to != from else { return }
        let moved = list.remove(at: from)
        list.insert(moved, at: to)
        for (rank, n) in list.enumerated() {
            guard writable, let i = notes.firstIndex(where: { $0.id == n.id }),
                  notes[i].order != Double(rank) else { continue }
            notes[i].order = Double(rank)
            persist(notes[i])
        }
    }

    func move(id: String, before otherID: String?) {
        guard writable, let i = notes.firstIndex(where: { $0.id == id }) else { return }
        let list = active
        let newOrder: Double
        if let otherID, let target = list.firstIndex(where: { $0.id == otherID }) {
            let upper = list[target].order
            let lower = target > 0 ? list[target - 1].order : upper - 2
            newOrder = (upper + lower) / 2
        } else {
            newOrder = (list.map(\.order).max() ?? 0) + 1
        }
        notes[i].order = newOrder
        persist(notes[i])
    }

    /// Bulk insert used by import — returns how many notes landed.
    @discardableResult
    func ingest(_ incoming: [Note]) -> Int {
        guard writable else { return 0 }
        var added = 0
        var base = (notes.map(\.order).min() ?? 0) - Double(incoming.count)
        for var n in incoming.sorted(by: { $0.order < $1.order }) {
            if notes.contains(where: { $0.id == n.id }) { n.id = UUID().uuidString }
            n.order = base
            base += 1
            guard NoteColor.all.indices.contains(n.color) else {
                report(PersistenceError.invalidColor)
                continue
            }
            notes.append(n)
            if persist(n) { added += 1 }
        }
        return added
    }

    private func seedWelcomeNote() {
        create(body: L10n.text("welcome.note_body"), color: 0)
    }
}
