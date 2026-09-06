import Combine
import Foundation

/// Runs sync passes against the iCloud Drive folder.
///
/// Main thread only in production. It mutates NoteStore, which every deck,
/// window and editor observes, and a pass is a few dozen small file reads — a
/// background queue would cost more in synchronisation than it could save.
/// (The test binary drives it directly with no run loop, so this is a
/// convention, not a precondition.)
final class CloudSync {
    static let shared = CloudSync(folder: CloudFolderGateway(), store: NoteStore.shared)

    private(set) var lastSync: Date?

    private let folder: SyncFolderGateway
    private let store: NoteStoring
    private var index: CloudSyncIndex
    private let indexURL: URL
    private var isRunning = false
    /// Notes parsed during the scan, so performing an action never re-parses a
    /// document that was already parsed this pass.
    private var scanned: [String: Note] = [:]
    /// Lowercased file names already spoken for this pass — everything the
    /// folder held when the pass began, plus everything written since. Built
    /// from the index alone, this missed every name on a first sync and let two
    /// notes overwrite each other.
    private var claimed: Set<String> = []

    init(folder: SyncFolderGateway, store: NoteStoring,
         indexURL: URL = CloudSyncIndex.defaultURL) {
        self.folder = folder
        self.store = store
        self.indexURL = indexURL
        self.index = CloudSyncIndex.load(from: indexURL)
    }

    /// One pass. Returns false when there was nothing it could do.
    @discardableResult
    func syncNow() -> Bool {
        guard Settings.cloudSyncEnabled, !isRunning else { return false }
        // Every deletion below is gated on this. With no folder, every file looks
        // deleted and the pass would empty the deck.
        guard folder.isAvailable, folder.ensureFolder() else {
            NSLog("Noty cloud: iCloud Drive is unavailable — skipping this pass")
            return false
        }

        isRunning = true
        defer { isRunning = false; scanned.removeAll(); claimed.removeAll() }

        let scan = folder.scan()
        claimed = Set(scan.allNames.map { $0.lowercased() })
        let remote = remoteFiles(from: scan)
        // A document that was listed but could not be read is still *there*.
        // Folding it in here is what stops it looking like a deletion.
        let seen = Set(remote.map(\.fileName))
        let unresolved = scan.unresolved.union(scan.documents.keys.filter { !seen.contains($0) })

        var changed = false
        for action in SyncPlan.actions(notes: store.notes, remote: remote,
                                       unresolved: unresolved, index: index) {
            perform(action)
            changed = true
        }
        if changed { index.save(to: indexURL) }
        lastSync = Date()
        return true
    }

    /// Builds the planner's view of the folder, reading only what moved. A file
    /// whose date matches what the index recorded is described from the index,
    /// which is what keeps a quiet pass down to one directory listing.
    private func remoteFiles(from scan: FolderScan) -> [SyncPlan.RemoteFile] {
        var out: [SyncPlan.RemoteFile] = []
        for (name, fileModified) in scan.documents.sorted(by: { $0.key < $1.key }) {
            if let id = index.id(forFileName: name),
               let entry = index.entries[id], entry.fileModified == fileModified {
                out.append(SyncPlan.RemoteFile(fileName: name, noteID: id,
                                               declaredModified: entry.syncedModified,
                                               fileModified: fileModified))
                continue
            }
            guard let text = folder.read(name) else {
                // Listed a moment ago, unreadable now. Say nothing about it —
                // `syncNow` folds this name into the unresolved set below.
                continue
            }
            let parsed = NoteDocument.parse(
                text, fallbackTitle: (name as NSString).deletingPathExtension)
            scanned[name] = parsed.note
            out.append(SyncPlan.RemoteFile(
                fileName: name,
                noteID: parsed.hasIdentity ? parsed.note.id : nil,
                declaredModified: parsed.hasIdentity ? parsed.note.modified : .distantPast,
                fileModified: fileModified))
        }
        return out
    }

    // MARK: Performing

    private func perform(_ action: SyncPlan.Action) {
        switch action {
        case .push(let id, let existing):
            push(noteID: id, existingFileName: existing)
        case .pull(let name):
            pull(fileName: name)
        case .reindex(let id, let name):
            guard let note = store.note(id: id),
                  let fileModified = folder.modificationDate(of: name) else { return }
            index.record(noteID: id, fileName: name,
                         noteModified: note.modified, fileModified: fileModified)
        case .adopt(let name):
            adopt(fileName: name)
        case .deleteLocal(let id):
            store.delete(id: id)          // keeps the existing ten-second undo
            index.forget(noteID: id)
        case .deleteRemote(let name):
            folder.remove(name)
            if let id = index.id(forFileName: name) { index.forget(noteID: id) }
        case .conflict(let id, let name, let localWins):
            resolve(noteID: id, fileName: name, localWins: localWins)
        }
    }

    private func push(noteID: String, existingFileName: String?) {
        guard let note = store.note(id: noteID) else { return }
        let indexed = index.entries[noteID]?.fileName

        let name: String
        if let existing = existingFileName, existing != indexed {
            // Renamed on another device. Their name wins — deriving our own here
            // would recreate the old file beside theirs.
            name = existing
        } else {
            var taken = claimed
            if let existing = existingFileName { taken.remove(existing.lowercased()) }
            if let indexed { taken.remove(indexed.lowercased()) }
            name = CloudFolder.fileName(for: note, avoiding: taken)
        }
        claimed.insert(name.lowercased())

        guard folder.write(NoteDocument.render(note), named: name) else { return }

        // Remove the document this pass actually saw, not the one the index
        // remembers — that is the difference between a rename and a duplicate.
        if let obsolete = existingFileName ?? indexed, obsolete != name {
            folder.remove(obsolete)
            claimed.remove(obsolete.lowercased())
        }
        index.record(noteID: noteID, fileName: name,
                     noteModified: note.modified,
                     fileModified: folder.modificationDate(of: name) ?? Date())
    }

    private func pull(fileName: String) {
        guard var incoming = scanned[fileName],
              let fileModified = folder.modificationDate(of: fileName) else { return }
        // A foreign editor leaves the header's date stale, so take the later of
        // the two or the deck would show a time from before the edit.
        incoming.modified = max(incoming.modified, fileModified)
        store.absorb(incoming)
        index.record(noteID: incoming.id, fileName: fileName,
                     noteModified: incoming.modified, fileModified: fileModified)
    }

    private func adopt(fileName: String) {
        guard var incoming = scanned[fileName],
              let fileModified = folder.modificationDate(of: fileName) else { return }

        incoming.id = UUID().uuidString
        incoming.created = fileModified
        incoming.modified = fileModified
        incoming.order = (store.active.map(\.order).min() ?? 0) - 1
        incoming.color = abs(fileName.hashValue) % NoteColor.all.count
        store.absorb(incoming)

        // Write it back so it carries an identity from now on. Keep the filename
        // the person chose on their phone.
        guard folder.write(NoteDocument.render(incoming), named: fileName) else { return }
        index.record(noteID: incoming.id, fileName: fileName,
                     noteModified: incoming.modified,
                     fileModified: folder.modificationDate(of: fileName) ?? fileModified)
    }

    // MARK: Conflicts

    /// The version that lost, as a plain document with **no** front-matter. With
    /// no identity it can never sync back and can never become a second note —
    /// it sits in the folder to be read in the Files app and deleted by hand.
    static func conflictDocument(for note: Note) -> String {
        "# " + note.displayTitle + "\n\n" + Tasks.toMarkdown(note.body)
    }

    private func resolve(noteID: String, fileName: String, localWins: Bool) {
        guard let remoteNote = scanned[fileName],
              let localNote = store.note(id: noteID) else { return }

        let loser = localWins ? remoteNote : localNote
        folder.writeConflict(Self.conflictDocument(for: loser), named: fileName)
        NSLog("Noty cloud: conflict on \(fileName) — kept a copy in \(CloudFolder.conflictsFolderName)")

        if localWins {
            push(noteID: noteID, existingFileName: fileName)
        } else {
            pull(fileName: fileName)
        }
    }

    // MARK: Scheduling

    private var timer: Timer?
    private var bag = Set<AnyCancellable>()
    private var pending: DispatchWorkItem?

    /// Start or stop according to the preference. Safe to call repeatedly.
    func reload() {
        Settings.cloudSyncEnabled ? start() : stop()
    }

    private func start() {
        guard timer == nil else { return }
        // A note changed here: write it out, but not on every keystroke — the
        // editor autosaves 250 ms after typing stops and each save republishes.
        NoteStore.shared.$notes
            .sink { [weak self] _ in self?.scheduleLocalPush() }
            .store(in: &bag)

        timer = Timer.scheduledTimer(withTimeInterval: Settings.cloudSyncInterval,
                                     repeats: true) { [weak self] _ in
            self?.syncNow()
        }
        syncNow()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pending?.cancel()
        pending = nil
        bag.removeAll()
    }

    /// `$notes` fires while a pass is applying its own pulls; ignoring those is
    /// what keeps a sync from feeding itself.
    private func scheduleLocalPush() {
        guard !isRunning else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncNow() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}
