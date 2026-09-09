import Foundation

/// The iCloud Drive folder Noty mirrors notes into.
///
/// This is a plain path, not a ubiquity container: a non-sandboxed app may read
/// and write it with no iCloud entitlement, and the system's own daemon does the
/// syncing. CloudKit and ubiquity containers both need an entitlement that needs
/// a paid developer account — see
/// docs/superpowers/specs/2026-09-06-icloud-drive-sync.md.
enum CloudFolder {
    static let folderName = "Noty"
    static let fileExtension = "md"

    static var driveRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs",
                                    isDirectory: true)
    }

    static var url: URL { driveRoot.appendingPathComponent(folderName, isDirectory: true) }

    /// iCloud Drive only has a root when the user is signed in and Drive is on.
    /// Every destructive decision in the sync engine is gated on this: with no
    /// folder, a missing file means nothing at all.
    static var isAvailable: Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: driveRoot.path,
                                                    isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    @discardableResult
    static func ensureFolder() -> Bool {
        guard isAvailable else { return false }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            NSLog("Noty cloud: cannot create \(url.path) — \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Names

    /// Identity lives in the front-matter, so a filename is free to follow the
    /// title around. `avoiding` holds lowercased names already claimed in this
    /// pass, since the folder is case-insensitive on a stock Mac.
    static func fileName(for note: Note, avoiding taken: Set<String>) -> String {
        // Deliberately not `displayTitle`: its empty case is the localized
        // "Untitled", which would rename every untitled note's file the moment
        // the app language changed.
        let source = note.hasCustomTitle ? note.title : Note.derivedTitle(from: note.body)
        let cleaned = source
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t"))
            .joined(separator: "-")
            .replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        var base = String(cleaned.prefix(80))
        // A leading dot hides the file from Finder and the Files app, which is the
        // one thing this feature exists to avoid.
        if base.isEmpty || base.hasPrefix(".") { base = "note-" + note.id.prefix(8) }

        var candidate = "\(base).\(fileExtension)"
        var suffix = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(base)-\(suffix).\(fileExtension)"
            suffix += 1
        }
        return candidate
    }

    /// Conflict copies live in their own subdirectory. A marker inside the
    /// filename could always be forged by a note title — and was: a note called
    /// "Refactor (conflict resolution)" filtered itself out of the folder and
    /// was then deleted as remotely-missing. A directory cannot be forged,
    /// because `fileName(for:)` never produces a path separator.
    static let conflictsFolderName = "Conflicts"

    static var conflictsURL: URL {
        url.appendingPathComponent(conflictsFolderName, isDirectory: true)
    }

    static func conflictName(for original: String, at date: Date) -> String {
        let base = (original as NSString).deletingPathExtension
        return base + " (conflict " + Fmt.fileStamp.string(from: date) + ").\(fileExtension)"
    }

    @discardableResult
    static func writeConflict(_ text: String, named fileName: String,
                              in directory: URL = CloudFolder.url) -> Bool {
        let folder = directory.appendingPathComponent(conflictsFolderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            NSLog("Noty cloud: cannot create the conflicts folder — \(error.localizedDescription)")
            return false
        }
        return write(text, to: folder.appendingPathComponent(conflictName(for: fileName, at: Date())))
    }

    // MARK: Contents

    /// An evicted iCloud item is stored as `.Shopping.md.icloud` — hidden, and
    /// with a different extension. A listing that skipped hidden files and kept
    /// only `.md` never saw it, so eviction was indistinguishable from deletion
    /// and the note was deleted. Resolve both spellings to one document name.
    static func resolvedName(of url: URL) -> (name: String, downloaded: Bool)? {
        let raw = url.lastPathComponent
        let suffix = "." + fileExtension
        if raw.hasPrefix("."), raw.hasSuffix(".icloud") {
            let inner = String(raw.dropFirst().dropLast(".icloud".count))
            guard inner.lowercased().hasSuffix(suffix) else { return nil }
            return (inner, false)
        }
        guard !raw.hasPrefix("."), raw.lowercased().hasSuffix(suffix) else { return nil }
        return (raw, true)
    }

    /// One pass's view of the folder: what could be read, and what is there but
    /// not readable yet. A placeholder gets a download kicked off so a later
    /// pass can see it; it is never treated as absent.
    static func scan(in directory: URL = CloudFolder.url) -> FolderScan {
        guard let items = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsSubdirectoryDescendants]) else { return FolderScan() }

        var out = FolderScan()
        for url in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let resolved = resolvedName(of: url) else { continue }
            guard resolved.downloaded else {
                try? FileManager.default.startDownloadingUbiquitousItem(
                    at: directory.appendingPathComponent(resolved.name))
                out.unresolved.insert(resolved.name)
                continue
            }
            guard ensureDownloaded(url), let date = modificationDate(of: url) else {
                out.unresolved.insert(resolved.name)
                continue
            }
            out.documents[resolved.name] = date
        }
        return out
    }

    /// Documents whose contents are here. Kept for the Settings pane and for
    /// anything that only needs the readable set.
    static func documentURLs(in directory: URL = CloudFolder.url) -> [URL] {
        scan(in: directory).documents.keys
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    // MARK: I/O

    /// iCloud evicts file contents and leaves a placeholder. Ask for the bytes
    /// back and report whether they are actually here yet — a caller that gets
    /// `false` must skip the file this pass rather than treat it as empty.
    @discardableResult
    static func ensureDownloaded(_ file: URL) -> Bool {
        guard let values = try? file.resourceValues(
                forKeys: [.ubiquitousItemDownloadingStatusKey]),
              let status = values.ubiquitousItemDownloadingStatus else { return true }
        if status == .current { return true }
        try? FileManager.default.startDownloadingUbiquitousItem(at: file)
        return false
    }

    static func read(_ file: URL) -> String? {
        guard ensureDownloaded(file) else { return nil }
        var text: String?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [],
                                       error: &coordinationError) { url in
            text = try? String(contentsOf: url, encoding: .utf8)
        }
        if let coordinationError {
            NSLog("Noty cloud: read \(file.lastPathComponent) — \(coordinationError.localizedDescription)")
        }
        return text
    }

    @discardableResult
    static func write(_ text: String, to file: URL) -> Bool {
        var ok = false
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing,
                                       error: &coordinationError) { url in
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                ok = true
            } catch {
                NSLog("Noty cloud: write \(url.lastPathComponent) — \(error.localizedDescription)")
            }
        }
        if let coordinationError {
            NSLog("Noty cloud: write \(file.lastPathComponent) — \(coordinationError.localizedDescription)")
        }
        return ok
    }

    @discardableResult
    static func remove(_ file: URL) -> Bool {
        var ok = false
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forDeleting,
                                       error: &coordinationError) { url in
            do {
                try FileManager.default.removeItem(at: url)
                ok = true
            } catch {
                NSLog("Noty cloud: delete \(url.lastPathComponent) — \(error.localizedDescription)")
            }
        }
        if let coordinationError {
            NSLog("Noty cloud: delete \(file.lastPathComponent) — \(coordinationError.localizedDescription)")
        }
        return ok
    }

    static func modificationDate(of file: URL) -> Date? {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    // MARK: Pass view
}
