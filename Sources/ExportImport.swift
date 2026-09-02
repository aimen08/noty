import AppKit
import UniformTypeIdentifiers

// MARK: - Archive format

struct StickyArchive: Codable {
    var version = 2
    var app = "Noty"
    var exported = Date()
    var notes: [StickyNote]
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

    init(_ n: Note) {
        id = n.id; title = n.title; body = n.body
        color = n.color; colorName = n.palette.name
        created = n.created; modified = n.modified
        archived = n.archived; order = n.order
        textDirection = n.textDirection
    }

    var note: Note {
        Note(id: id, title: title.isEmpty ? Note.derivedTitle(from: body) : title,
             body: body, color: color, created: created, modified: modified,
             archived: archived, textDirection: textDirection ?? .automatic,
             order: order)
    }
}

// MARK: - Export / import

enum Transfer {

    enum Format { case markdown, plainText, singleFile, stickies }

    static func export(_ format: Format, notes: [Note]) {
        guard !notes.isEmpty else {
            alert(String(localized: "Nothing to export"), String(localized: "There are no notes yet."))
            return
        }
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
        panel.prompt = String(localized: "Export Here")
        panel.message = String.localizedStringWithFormat(
            NSLocalizedString("export_file_count", comment: "Export file count"), notes.count, ext.uppercased())
        guard panel.runModal() == .OK, let dir = panel.url else { return }

        var used = Set<String>()
        var written = 0
        for n in notes {
            var base = safeName(n)
            var candidate = base
            var i = 2
            while used.contains(candidate.lowercased()) { candidate = "\(base)-\(i)"; i += 1 }
            used.insert(candidate.lowercased())
            base = candidate
            let url = dir.appendingPathComponent("\(base).\(ext)")
            do {
                try render(n).write(to: url, atomically: true, encoding: .utf8)
                written += 1
            } catch {
                NSLog("Noty export failed for \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        reveal(dir)
        if written < notes.count {
            alert(String(localized: "Export incomplete"),
                  String.localizedStringWithFormat(
                    NSLocalizedString("export_incomplete_count", comment: "Incomplete export count"),
                    notes.count, written))
        }
    }

    private static func exportSingle(_ notes: [Note]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Noty-\(Fmt.fileStamp.string(from: Date())).md"
        panel.allowedContentTypes = [.plainText]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let doc = notes.map { n -> String in
            """
            ## \(n.displayTitle)
            <!-- \(n.palette.name) · created \(Fmt.stamp.string(from: n.created)) · \
            modified \(Fmt.stamp.string(from: n.modified))\(n.archived ? " · archived" : "") -->

            \(Tasks.toMarkdown(n.body))
            """
        }.joined(separator: "\n\n---\n\n")

        let header = "# Noty export\n\n\(notes.count) notes · \(Fmt.stamp.string(from: Date()))\n\n---\n\n"
        write(header + doc, to: url)
    }

    private static func exportArchive(_ notes: [Note]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Noty-\(Fmt.fileStamp.string(from: Date())).stickies"
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let archive = StickyArchive(notes: notes.map(StickyNote.init))
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        do {
            try enc.encode(archive).write(to: url, options: .atomic)
            reveal(url)
        } catch {
            alert(String(localized: "Export failed"),
                  String.localizedStringWithFormat(
                    NSLocalizedString("Export failed: %@", comment: "Export failure detail"),
                    error.localizedDescription))
        }
    }

    private static func markdownBody(_ n: Note) -> String {
        let source = Tasks.toMarkdown(n.body)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let first = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
        // Promote a bare first line to an H1 so the file reads as a document.
        if !first.isEmpty && !first.hasPrefix("#") && !first.hasPrefix("- [") {
            return (["# " + first] + lines.dropFirst()).joined(separator: "\n")
        }
        return source
    }

    // MARK: Import

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
        panel.message = String(localized: "Choose a .stickies archive, or Markdown / text files.")
        guard panel.runModal() == .OK else { return }

        var incoming: [Note] = []
        var failed: [String] = []

        for url in panel.urls {
            if url.pathExtension.lowercased() == "stickies" {
                guard let data = try? Data(contentsOf: url) else { failed.append(url.lastPathComponent); continue }
                let dec = JSONDecoder()
                dec.dateDecodingStrategy = .iso8601
                if let archive = try? dec.decode(StickyArchive.self, from: data) {
                    incoming += archive.notes.map(\.note)
                } else {
                    failed.append(url.lastPathComponent)
                }
            } else {
                guard let body = try? String(contentsOf: url, encoding: .utf8) else {
                    failed.append(url.lastPathComponent); continue
                }
                var n = Note()
                n.body = Tasks.fromMarkdown(body)
                n.title = Note.derivedTitle(from: body)
                if n.title.isEmpty { n.title = url.deletingPathExtension().lastPathComponent }
                n.color = abs(url.lastPathComponent.hashValue) % NoteColor.all.count
                incoming.append(n)
            }
        }

        let added = NoteStore.shared.ingest(incoming)
        if failed.isEmpty {
            alert(String(localized: "Import complete"),
                  String.localizedStringWithFormat(
                    NSLocalizedString("import_added_count", comment: "Imported note count"), added))
        } else {
            let addedMessage = String.localizedStringWithFormat(
                NSLocalizedString("import_added_count", comment: "Imported note count"), added)
            let failedMessage = String.localizedStringWithFormat(
                NSLocalizedString("Could not read: %@", comment: "Import failure files"),
                failed.joined(separator: ", "))
            alert(String(localized: "Import finished with problems"), "\(addedMessage) \(failedMessage)")
        }
    }

    // MARK: Helpers

    private static func safeName(_ n: Note) -> String {
        let raw = n.displayTitle
        let cleaned = raw.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(cleaned.prefix(80))
        return trimmed.isEmpty ? "note-\(n.id.prefix(8))" : trimmed
    }

    private static func write(_ s: String, to url: URL) {
        do {
            try s.write(to: url, atomically: true, encoding: .utf8)
            reveal(url)
        } catch {
            alert(String(localized: "Export failed"),
                  String.localizedStringWithFormat(
                    NSLocalizedString("Export failed: %@", comment: "Export failure detail"),
                    error.localizedDescription))
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
