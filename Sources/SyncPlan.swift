import Foundation

/// Decides what one sync pass should do. Deliberately pure — no file system, no
/// NoteStore, no clock — so the whole decision table is covered by tests and the
/// runner that performs the actions stays thin enough to read.
enum SyncPlan {

    /// One document found in the sync folder.
    struct RemoteFile: Equatable {
        var fileName: String
        /// nil when the file carries no `noty-id` header — a note somebody wrote
        /// from scratch on a phone.
        var noteID: String?
        /// The `modified` written in the front-matter. `.distantPast` when there
        /// is no header to read it from.
        var declaredModified: Date
        /// The file's own modification date. An editor that knows nothing about
        /// the header bumps this and not that, so this is the change *signal*.
        var fileModified: Date

        /// The best evidence of when the remote side last changed — used to
        /// decide who wins, where the signal only says that something did.
        var effectiveModified: Date { max(declaredModified, fileModified) }
    }

    enum Action: Equatable {
        /// `existingFileName` is the document the pass actually observed for this
        /// note, when there was one. Removing the *indexed* name instead left a
        /// rename made on another device behind as a second file with the same
        /// identity.
        case push(noteID: String, existingFileName: String?)
        case pull(fileName: String)
        /// The two sides already agree and only the bookkeeping is missing.
        case reindex(noteID: String, fileName: String)
        case adopt(fileName: String)
        case deleteLocal(noteID: String)
        case deleteRemote(fileName: String)
        case conflict(noteID: String, fileName: String, localWins: Bool)
    }

    /// `unresolved` names documents that are in the folder but whose contents
    /// could not be read this pass — an iCloud placeholder, or a failed read.
    /// Deletion must follow from evidence that a file is gone, never from the
    /// absence of its contents.
    ///
    /// The caller must also have established that the folder itself exists.
    /// With no folder every file looks deleted, and this would empty the deck.
    static func actions(notes: [Note], remote: [RemoteFile],
                        unresolved: Set<String>, index: CloudSyncIndex) -> [Action] {
        var out: [Action] = []
        let localIDs = Set(notes.map(\.id))
        // Group by identity first. Two documents can claim one `noty-id` —
        // duplicating a note's file copies its front matter along with its body —
        // and a last-wins dictionary made one of them vanish from the plan
        // entirely: never pulled, never pushed, never deleted.
        var identified: [String: [RemoteFile]] = [:]
        var adoptions: [String] = []
        for file in remote {
            guard let id = file.noteID else {
                adoptions.append(file.fileName)     // written from scratch elsewhere
                continue
            }
            identified[id, default: []].append(file)
        }

        var remoteByID: [String: RemoteFile] = [:]
        for id in identified.keys.sorted() {
            let files = identified[id] ?? []
            guard files.count > 1 else {
                remoteByID[id] = files.first
                continue
            }
            // The document the index already names is this note's home. With no
            // index entry, the newest wins, with the name as a stable tiebreak.
            let newest = files.max { a, b in
                a.effectiveModified == b.effectiveModified
                    ? a.fileName < b.fileName
                    : a.effectiveModified < b.effectiveModified
            }
            let indexedName = index.entries[id]?.fileName
            let keeper = files.first { $0.fileName == indexedName } ?? newest ?? files[0]
            remoteByID[id] = keeper
            // Copying a note's file means "I want a second note like this one".
            // `adopt` gives it a fresh identity and writes the header back.
            adoptions += files.filter { $0.fileName != keeper.fileName }.map(\.fileName)
        }

        for name in adoptions.sorted() {
            out.append(.adopt(fileName: name))
        }

        for note in notes {
            let known = index.entries[note.id]
            guard let file = remoteByID[note.id] else {
                guard let known else {
                    out.append(.push(noteID: note.id, existingFileName: nil))
                    continue
                }
                // The file is still there; we just cannot see into it yet.
                guard !unresolved.contains(known.fileName) else { continue }
                out.append(.deleteLocal(noteID: note.id))
                continue
            }
            // With no index entry both sides look new. When the document
            // still declares the timestamp the note has, they are the same
            // version and there is nothing to resolve — a lost index used to
            // turn every note into a conflict and revert every local copy.
            if known == nil, note.modified == file.declaredModified {
                out.append(.reindex(noteID: note.id, fileName: file.fileName))
                continue
            }
            // With no index entry both sides look new; a conflict is the honest
            // reading, and it preserves whichever version loses.
            let localChanged = known.map { note.modified > $0.syncedModified } ?? true
            let remoteChanged = known.map { file.fileModified > $0.fileModified } ?? true

            switch (localChanged, remoteChanged) {
            case (false, false):
                break
            case (true, false):
                out.append(.push(noteID: note.id, existingFileName: file.fileName))
            case (false, true):
                out.append(.pull(fileName: file.fileName))
            case (true, true):
                let remoteDate = file.effectiveModified
                guard note.modified != remoteDate else { break }   // the same edit, seen twice
                out.append(.conflict(noteID: note.id, fileName: file.fileName,
                                     localWins: note.modified > remoteDate))
            }
        }

        // Identified files with no note behind them.
        for file in remote.sorted(by: { $0.fileName < $1.fileName }) {
            guard let id = file.noteID, !localIDs.contains(id) else { continue }
            out.append(index.entries[id] == nil ? .pull(fileName: file.fileName)
                                                : .deleteRemote(fileName: file.fileName))
        }
        return out
    }
}
