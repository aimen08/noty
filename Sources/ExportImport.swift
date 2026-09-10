import AppKit
import UniformTypeIdentifiers

// MARK: - Archive format

struct StickyArchive: Codable {
    var version = 3
    var app = "Noty"
    var exported = Date()
    var notes: [StickyNote]
    /// Image id → base64 file bytes for every `noty-img` token used by `notes`,
    /// so an archive is self-contained. Optional because archives written
    /// before image support (version ≤ 2) simply lack the key.
    var images: [String: String]?
}

struct StickyNote: Codable {
    var id: String
    var title: String
    var body: String
    var color: Int
    var colorName: String
    var created: Date
    var modified: Date
    var archived: Bool
    var order: Double
    var textDirection: NoteTextDirection?
    var pinned: Bool?

    init(_ n: Note) {
        id = n.id; title = n.title; body = n.body
        color = n.color; colorName = n.palette.name
        created = n.created; modified = n.modified
        archived = n.archived; order = n.order
        textDirection = n.textDirection
        pinned = n.pinned
    }

    var note: Note {
        Note(id: id, title: title,
             body: body, color: color, created: created, modified: modified,
             archived: archived, pinned: pinned ?? false, textDirection: textDirection ?? .automatic,
             order: order)
    }
}

// MARK: - Export / import

enum Transfer {

    enum Format { case markdown, plainText, singleFile, stickies }

    static func export(_ format: Format, notes: [Note]) {
        guard !notes.isEmpty else {
            alert(L10n.text("export.empty_title"), L10n.text("export.empty_body"))
            return
        }
        _ = NoteStore.shared.flushAll()
        NSApp.activate()
        switch format {
        case .markdown:  exportPerFile(notes, ext: "md",  render: markdownBody)
        case .plainText: exportPerFile(notes, ext: "txt", render: { $0.body })
        case .singleFile: exportSingle(notes)
        case .stickies:  exportArchive(notes)
        }
    }

    // One file per note, into a folder the user picks.
    private static func exportPerFile(_ notes: [Note], ext: String, render: (Note) -> String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L10n.text("export.here")
        panel.message = L10n.plural("export.choose_folder", notes.count, ext.uppercased())
        guard panel.runModal() == .OK, let dir = panel.url else { return }

        var used = Set<String>()
        var written = 0
        for n in notes {
            do {
                _ = try writeUniqueFile(render(n), named: safeName(n), ext: ext,
                                        directory: dir, used: &used)
                written += 1
            } catch {
                NSLog("Noty export failed: \(error.localizedDescription)")
            }
        }
        reveal(dir)
        if written < notes.count {
            alert(L10n.text("export.incomplete_title"),
                  L10n.format("export.incomplete_body", written,
                              L10n.plural("notes.count", notes.count)))
        }
    }

    private static func exportSingle(_ notes: [Note]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = L10n.format(
            "export.markdown_filename", Fmt.fileStamp.string(from: Date()))
        panel.allowedContentTypes = [.plainText]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let doc = notes.map { n -> String in
            let archiveSuffix = n.archived ? L10n.text("export.metadata_archived_suffix") : ""
            let metadata = L10n.format(
                "export.metadata", n.palette.localizedName,
                Fmt.stamp.string(from: n.created), Fmt.stamp.string(from: n.modified),
                archiveSuffix)
            return """
            ## \(n.displayTitle)
            <!-- \(metadata) -->

            \(Tasks.toMarkdown(n.body))
            """
        }.joined(separator: "\n\n---\n\n")

        let header = "# \(L10n.text("export.document_title"))\n\n"
            + "\(L10n.plural("notes.count", notes.count)) · \(Fmt.stamp.string(from: Date()))\n\n---\n\n"
        write(header + doc, to: url)
    }

    private static func exportArchive(_ notes: [Note]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = L10n.format(
            "export.archive_filename", Fmt.fileStamp.string(from: Date()))
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var archive = StickyArchive(notes: notes.map(StickyNote.init))
        let images = archiveImages(for: notes)
        archive.images = images.isEmpty ? nil : images
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        do {
            try enc.encode(archive).write(to: url, options: .atomic)
            reveal(url)
        } catch {
            alert(L10n.text("export.failed_title"), error.localizedDescription)
        }
    }

    /// The bytes behind every image token in the exported notes, keyed by id.
    /// Ids are stable across export/import, so one image shared by several
    /// notes is stored once.
    private static func archiveImages(for notes: [Note]) -> [String: String] {
        var out: [String: String] = [:]
        for n in notes {
            for id in ImageStore.referencedIDs(in: n.body) {
                guard out[id] == nil, let data = ImageStore.data(id: id) else { continue }
                out[id] = data.base64EncodedString()
            }
        }
        return out
    }

    private static func markdownBody(_ n: Note) -> String {
        let source = Tasks.toMarkdown(n.body)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let first = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
        // Promote a bare first line to an H1 so the file reads as a document.
        // An image token must stay verbatim, or the round trip loses the image.
        if !first.isEmpty && !first.hasPrefix("#") && !first.hasPrefix("- [")
            && !Note.isImageTokenLine(first) {
            return (["# " + first] + lines.dropFirst()).joined(separator: "\n")
        }
        return source
    }

    // MARK: Import

    static func decodeArchive(_ data: Data) throws -> [Note] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(StickyArchive.self, from: data)
        guard (1...3).contains(archive.version) else {
            throw PersistenceError.database(L10n.text("import.invalid_archive"))
        }
        guard archive.notes.allSatisfy({ NoteColor.all.indices.contains($0.color) }) else {
            throw PersistenceError.invalidColor
        }
        let remapped = restoreImages(archive.images ?? [:])
        return archive.notes.map { sticky in
            var n = sticky.note
            if !remapped.isEmpty {
                n.body = remapImageIDs(in: n.body, mapping: remapped)
            }
            return n
        }
    }

    static func importFiles() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        var types: [UTType] = [.plainText, .text]
        if let sticky = UTType(filenameExtension: "stickies") { types.append(sticky) }
        panel.allowedContentTypes = types
        panel.allowsOtherFileTypes = true
        panel.message = L10n.text("import.choose_files")
        guard panel.runModal() == .OK else { return }

        var incoming: [Note] = []
        var failed: [String] = []

        for url in panel.urls {
            if url.pathExtension.lowercased() == "stickies" {
                guard let data = try? Data(contentsOf: url) else { failed.append(url.lastPathComponent); continue }
                if let notes = try? decodeArchive(data) {
                    incoming += notes
                } else {
                    failed.append(url.lastPathComponent)
                }
            } else {
                guard let body = try? String(contentsOf: url, encoding: .utf8) else {
                    failed.append(url.lastPathComponent); continue
                }
                var n = Note()
                n.body = Tasks.fromMarkdown(body)
                if Note.derivedTitle(from: n.body).isEmpty { n.title = url.deletingPathExtension().lastPathComponent }
                n.color = Int(url.lastPathComponent.hashValue.magnitude % UInt(NoteColor.all.count))
                incoming.append(n)
            }
        }

        let added = NoteStore.shared.ingest(incoming)
        if added < incoming.count { failed.append(L10n.text("storage.import_unsaved")) }
        if failed.isEmpty {
            alert(L10n.text("import.complete_title"), L10n.plural("import.added", added))
        } else {
            alert(L10n.text("import.problems_title"),
                  L10n.format("import.problems_body", L10n.plural("import.added", added),
                              failed.joined(separator: ", ")))
        }
    }

    // MARK: Helpers

    /// Reserve the destination exclusively so existing files (including symlinks)
    /// survive even if another export writes into the folder at the same time.
    static func writeUniqueFile(_ text: String, named base: String, ext: String,
                                directory: URL, used: inout Set<String>) throws -> URL {
        let existing = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        used.formUnion(existing.map { $0.precomposedStringWithCanonicalMapping.lowercased() })
        var suffix = 1
        while true {
            let name = (suffix == 1 ? base : "\(base)-\(suffix)") + "." + ext
            let folded = name.precomposedStringWithCanonicalMapping.lowercased()
            suffix += 1
            guard !used.contains(folded) else { continue }
            let url = directory.appendingPathComponent(name)
            do {
                try Data(text.utf8).write(to: url, options: .withoutOverwriting)
                used.insert(folded)
                return url
            } catch let error as NSError {
                guard error.domain == NSCocoaErrorDomain,
                      error.code == NSFileWriteFileExistsError else { throw error }
                used.insert(folded)
            }
        }
    }

    /// Writes an archive's bundled images back to disk. An id already present
    /// is the same image (export copies the file unchanged), so it is skipped
    /// and its tokens stay valid. `ImageStore.save` always mints a fresh id,
    /// so the returned old→new mapping must be applied to the imported bodies.
    private static func restoreImages(_ images: [String: String]) -> [String: String] {
        var remapped: [String: String] = [:]
        for (oldID, b64) in images {
            guard ImageStore.data(id: oldID) == nil else { continue }
            guard let data = Data(base64Encoded: b64),
                  let newID = ImageStore.save(data: data, ext: imageExt(for: data)) else { continue }
            if newID != oldID { remapped[oldID] = newID }
        }
        return remapped
    }

    /// Rewrites image tokens to the ids the images actually landed under.
    /// Tokens are replaced whole (preserving any width) in reverse order so
    /// the ranges stay valid against the original string.
    private static func remapImageIDs(in body: String, mapping: [String: String]) -> String {
        var result = body as NSString
        for token in ImageStore.tokens(in: body).reversed() {
            guard let newID = mapping[token.id] else { continue }
            result = result.replacingCharacters(
                in: token.range,
                with: ImageStore.token(id: newID, width: token.width)) as NSString
        }
        return result as String
    }

    /// Archives carry only the bytes, but `save(data:ext:)` wants an extension,
    /// so sniff the common formats. NSImage sniffs content too, so a wrong
    /// guess would only affect the file name, never rendering.
    private static func imageExt(for data: Data) -> String {
        let head = [UInt8](data.prefix(4))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if head.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        return "png"
    }

    private static func safeName(_ n: Note) -> String {
        let raw = n.displayTitle
        let cleaned = raw.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(cleaned.prefix(80))
        return trimmed.isEmpty
            ? L10n.format("export.default_note_name", String(n.id.prefix(8)))
            : trimmed
    }

    private static func write(_ s: String, to url: URL) {
        do {
            try s.write(to: url, atomically: true, encoding: .utf8)
            reveal(url)
        } catch {
            alert(L10n.text("export.failed_title"), error.localizedDescription)
        }
    }

    private static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func alert(_ title: String, _ body: String) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.alertStyle = .informational
        a.runModal()
    }
}
