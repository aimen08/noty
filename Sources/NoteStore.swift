import Foundation
import Combine

/// Observable in-memory model. SQLite is written through on every mutation;
/// the array is the single source of truth for every window and deck.
final class NoteStore: ObservableObject {
    static let shared = NoteStore()

    @Published private(set) var notes: [Note] = []
    /// Set when a note is deleted, cleared after the 10 s undo window elapses.
    @Published var pendingUndo: PendingDelete?

    private let store = Store()
    private var undoTimer: Timer?

    struct PendingDelete: Equatable {
        let note: Note
        let deadline: Date
    }

    private init() {
        notes = store.load()
        if notes.isEmpty { seedWelcomeNote() }
    }

    // MARK: Derived collections

    var active: [Note] { notes.filter { !$0.archived }.sorted { $0.order < $1.order } }
    var archived: [Note] { notes.filter { $0.archived }.sorted { $0.modified > $1.modified } }

    func note(id: String) -> Note? { notes.first { $0.id == id } }

    // MARK: Mutations

    @discardableResult
    func create(body: String = "", color: Int? = nil) -> Note {
        var n = Note()
        n.order = (active.map(\.order).min() ?? 0) - 1   // newest sits at the top of the deck
        n.color = color ?? (notes.count % NoteColor.all.count)
        n.body = body
        n.title = Note.derivedTitle(from: body)
        notes.append(n)
        store.upsert(n)
        return n
    }

    func updateBody(id: String, body: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        guard notes[i].body != body else { return }
        notes[i].body = body
        notes[i].title = Note.derivedTitle(from: body)
        notes[i].modified = Date()
        store.upsert(notes[i])
    }

    func togglePin(id: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].pinned.toggle()
        store.upsert(notes[i])
    }

    func cycleColor(id: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].color = (notes[i].color + 1) % NoteColor.all.count
        notes[i].modified = Date()
        store.upsert(notes[i])
    }

    func setColor(id: String, color: Int) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].color = color
        notes[i].modified = Date()
        store.upsert(notes[i])
    }

    func setTextDirection(id: String, direction: NoteTextDirection) {
        guard let i = notes.firstIndex(where: { $0.id == id }),
              notes[i].textDirection != direction else { return }
        notes[i].textDirection = direction
        notes[i].modified = Date()
        store.upsert(notes[i])
    }

    func setArchived(id: String, _ archived: Bool) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].archived = archived
        notes[i].modified = Date()
        if !archived { notes[i].order = (active.map(\.order).min() ?? 0) - 1 }
        store.upsert(notes[i])
    }

    /// Removes the note but keeps it recoverable for ten seconds.
    func delete(id: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        let doomed = notes[i]
        notes.remove(at: i)
        store.delete(id: id)
        pendingUndo = PendingDelete(note: doomed, deadline: Date().addingTimeInterval(10))
        undoTimer?.invalidate()
        undoTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.pendingUndo = nil }
        }
    }

    func undoDelete() {
        guard let p = pendingUndo else { return }
        undoTimer?.invalidate()
        notes.append(p.note)
        store.upsert(p.note)
        pendingUndo = nil
    }

    /// Move a note `slots` positions up or down the deck, rewriting the order
    /// column densely so repeated drags cannot drift the values apart.
    func reorder(id: String, by slots: Int) {
        var list = active
        guard slots != 0, let from = list.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(0, from + slots), list.count - 1)
        guard to != from else { return }
        let moved = list.remove(at: from)
        list.insert(moved, at: to)
        for (rank, n) in list.enumerated() {
            guard let i = notes.firstIndex(where: { $0.id == n.id }),
                  notes[i].order != Double(rank) else { continue }
            notes[i].order = Double(rank)
            store.upsert(notes[i])
        }
    }

    func move(id: String, before otherID: String?) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
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
        store.upsert(notes[i])
    }

    /// Bulk insert used by import — returns how many notes landed.
    @discardableResult
    func ingest(_ incoming: [Note]) -> Int {
        var added = 0
        var base = (notes.map(\.order).min() ?? 0) - 1
        for var n in incoming {
            if notes.contains(where: { $0.id == n.id }) { n.id = UUID().uuidString }
            n.order = base
            base -= 1
            notes.append(n)
            store.upsert(n)
            added += 1
        }
        return added
    }

    private func seedWelcomeNote() {
        create(body: """
        Welcome to Noty

        Your notes live at the edge of the screen. Slide the pointer to the \
        right edge and the deck fans out.

        ⌥⌘N  new note
        ⌥⌘A  all notes
        ⌥⌘L  archive

        Inside a note: Esc closes, ⌘F finds, ⌘. cycles the colour, \
        ⌘⌫ deletes with ten seconds to undo.
        """, color: 0)
    }
}
