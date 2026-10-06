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
        var count: Int = 1
    }

    init(store: Store = Store(), seedWelcome: Bool = true,
         onError: @escaping (Error) -> Void = NoteStore.showError) {
        self.store = store
        self.onError = onError
        do {
            notes = try store.load()
            removeOrphanedImages()
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

    var active: [Note] { notes.filter { !$0.archived && !$0.isTrashed }.sorted { $0.order < $1.order } }
    var archived: [Note] { notes.filter { $0.archived && !$0.isTrashed }.sorted { $0.modified > $1.modified } }

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
        guard writable, let i = notes.firstIndex(where: { $0.id == id && !$0.isTrashed }) else { return }
        guard notes[i].title != title else { return }
        notes[i].title = title
        notes[i].modified = Date()
        scheduleSave(id: id)
    }

    func updateBody(id: String, body: String) {
        guard writable, let i = notes.firstIndex(where: { $0.id == id && !$0.isTrashed }) else { return }
        guard notes[i].body != body else { return }
        notes[i].body = body
        notes[i].modified = Date()
        scheduleSave(id: id)
    }

    func togglePin(id: String) {
        guard writable, let i = notes.firstIndex(where: { $0.id == id && !$0.isTrashed }) else { return }
        notes[i].pinned.toggle()
        persist(notes[i])
    }

    func cycleColor(id: String) {
        guard writable, let i = notes.firstIndex(where: { $0.id == id && !$0.isTrashed }) else { return }
        notes[i].color = (notes[i].color + 1) % NoteColor.all.count
        notes[i].modified = Date()
        persist(notes[i])
    }

    func setColor(id: String, color: Int) {
        guard writable, let i = notes.firstIndex(where: { $0.id == id && !$0.isTrashed }) else { return }
        guard NoteColor.all.indices.contains(color) else { return }
        notes[i].color = color
        notes[i].modified = Date()
        persist(notes[i])
    }

    func setTextDirection(id: String, direction: NoteTextDirection) {
        guard writable, let i = notes.firstIndex(where: { $0.id == id && !$0.isTrashed }),
              notes[i].textDirection != direction else { return }
        notes[i].textDirection = direction
        notes[i].modified = Date()
        persist(notes[i])
    }

    func setArchived(id: String, _ archived: Bool) {
        guard writable, let i = notes.firstIndex(where: { $0.id == id && !$0.isTrashed }) else { return }
        notes[i].archived = archived
        notes[i].modified = Date()
        if !archived { notes[i].order = (active.map(\.order).min() ?? 0) - 1 }
        persist(notes[i])
    }

    var living: [Note] { notes.filter { !$0.isTrashed } }
    var trash: [Note] { notes.filter(\.isTrashed).sorted { $0.deletedAt! > $1.deletedAt! } }
    var projects: [String] { Array(Set(living.map(\.project).filter { !$0.isEmpty })).sorted() }
    var tags: [String] { Note.normalizedTags(living.flatMap(\.tags)).sorted() }

    @discardableResult
    private func commit(_ changed: [Note], removing ids: Set<String> = []) -> Bool {
        guard writable else { return false }
        do { try store.transaction(upserting: changed, deleting: Array(ids)) }
        catch { report(error); return false }
        for id in Set(changed.map(\.id)).union(ids) {
            saveWork.removeValue(forKey: id)?.cancel()
            unsavedIDs.remove(id)
        }
        let replacements = Dictionary(uniqueKeysWithValues: changed.map { ($0.id, $0) })
        let existing = Set(notes.map(\.id))
        notes = notes.filter { !ids.contains($0.id) }.map { replacements[$0.id] ?? $0 }
            + changed.filter { !existing.contains($0.id) }
        if unsavedIDs.isEmpty { lastError = nil }
        return true
    }

    @discardableResult
    func organize(ids: Set<String>, project: String? = nil, tags: [String]? = nil,
                  addingTags: Bool = false, color: Int? = nil, archived: Bool? = nil) -> Bool {
        let changed = notes.filter { ids.contains($0.id) && !$0.isTrashed }.map { old in
            var n = old
            if let project { n.project = project.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let tags { n.tags = Note.normalizedTags((addingTags ? n.tags : []) + tags) }
            if let color { n.color = color }
            if let archived { n.archived = archived }
            n.modified = Date()
            return n
        }
        return commit(changed)
    }

    /// Trash survives restarts; the toast is only a convenient immediate undo.
    func delete(id: String) { trash(ids: [id]) }

    @discardableResult
    func trash(ids: Set<String>) -> Bool {
        let originals = notes.filter { ids.contains($0.id) && !$0.isTrashed }
        let now = Date()
        let changed = originals.map { old in
            var n = old; n.deletedAt = now; n.modified = now; return n
        }
        guard !changed.isEmpty, commit(changed) else { return false }
        pendingUndo = PendingDelete(note: originals[0], deadline: now.addingTimeInterval(10), count: originals.count)
        pendingUndoIDs = Set(changed.map(\.id))
        undoTimer?.invalidate()
        undoTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            self?.pendingUndo = nil
            self?.pendingUndoIDs = []
        }
        return true
    }

    private var pendingUndoIDs = Set<String>()

    func undoDelete() {
        guard restore(ids: pendingUndoIDs) else { return }
        undoTimer?.invalidate()
        pendingUndo = nil
        pendingUndoIDs = []
    }

    @discardableResult
    func restore(ids: Set<String>) -> Bool {
        let changed = notes.filter { ids.contains($0.id) && $0.isTrashed }.map { old in
            var n = old; n.deletedAt = nil; n.modified = Date(); return n
        }
        return commit(changed)
    }

    @discardableResult
    func permanentlyDelete(ids: Set<String>) -> Bool {
        let removing = Set(trash.filter { ids.contains($0.id) }.map(\.id))
        guard commit([], removing: removing) else { return false }
        pendingUndoIDs.subtract(removing)
        if pendingUndoIDs.isEmpty { pendingUndo = nil }
        removeOrphanedImages()
        return true
    }

    /// Keep the originals recoverable and publish the merged note atomically.
    @discardableResult
    func merge(ids: Set<String>) -> Note? {
        let source = living.filter { ids.contains($0.id) }.sorted { $0.order < $1.order }
        guard source.count > 1 else { return nil }
        let now = Date()
        var merged = Note(title: source[0].displayTitle,
                          body: source.map { "## " + $0.displayTitle + "\n\n" + $0.body }
                            .joined(separator: "\n\n---\n\n"), color: source[0].color)
        merged.project = Set(source.map(\.project)).count == 1 ? source[0].project : ""
        merged.tags = Note.normalizedTags(source.flatMap(\.tags))
        merged.order = (active.map(\.order).min() ?? 0) - 1
        let originals = source.map { old in
            var n = old; n.deletedAt = now; n.modified = now; return n
        }
        return commit(originals + [merged]) ? merged : nil
    }

    /// Trashed notes still own their images until explicitly permanently deleted.
    private func removeOrphanedImages() {
        let used = Set(notes.flatMap { ImageStore.referencedIDs(in: $0.body) })
        let orphans = ImageStore.allIDs().filter { !used.contains($0) }
        if !orphans.isEmpty { ImageStore.delete(ids: orphans) }
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

    struct ImportResult {
        var added = 0
        var skipped = 0
        var failed = 0
    }

    @discardableResult
    func ingest(_ incoming: [Note]) -> Int { importNotes(incoming).added }

    func importNotes(_ incoming: [Note]) -> ImportResult {
        guard writable else { return ImportResult(failed: incoming.count) }
        var result = ImportResult()
        // Include trash: importing the same backup should not resurrect deleted notes.
        var fingerprints = Set(notes.map(NoteIdentity.fingerprint))
        var ids = Set(notes.map(\.id))
        var accepted: [Note] = []
        var base = (notes.map(\.order).min() ?? 0) - Double(incoming.count)
        for var n in incoming.sorted(by: { $0.order < $1.order }) {
            guard NoteColor.all.indices.contains(n.color) else { result.failed += 1; continue }
            let fingerprint = NoteIdentity.fingerprint(n)
            guard fingerprints.insert(fingerprint).inserted else { result.skipped += 1; continue }
            if ids.contains(n.id) { n.id = UUID().uuidString }
            ids.insert(n.id)
            n.order = base; base += 1
            accepted.append(n)
        }
        if commit(accepted) { result.added = accepted.count }
        else { result.failed += accepted.count }
        return result
    }

    /// Insert or replace a note wholesale, keeping the timestamps it arrives
    /// with. Sync uses this rather than `ingest`, which renumbers and re-ids its
    /// input because it is importing strangers — a synced note is the same note,
    /// carried here from another device.
    func absorb(_ note: Note) {
        guard writable else { return }
        if let i = notes.firstIndex(where: { $0.id == note.id }) {
            guard notes[i] != note else { return }
            notes[i] = note
        } else {
            notes.append(note)
        }
        persist(note)
    }

    private func seedWelcomeNote() {
        create(body: L10n.text("welcome.note_body"), color: 0)
    }
}
