import Foundation
import CryptoKit

enum NoteIdentity {
    /// Exact-content deduplication, including image bytes rather than local IDs.
    /// Metadata that gives identical text a different purpose remains significant.
    static func fingerprint(_ note: Note) -> String {
        var body = note.body.replacingOccurrences(of: "\r\n", with: "\n") as NSString
        for token in ImageStore.tokens(in: body as String).reversed() {
            guard let data = ImageStore.data(id: token.id) else { continue }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            body = body.replacingCharacters(in: token.range,
                with: "![image|\(token.width.map { String(describing: $0) } ?? "auto")](sha256:\(hash))") as NSString
        }
        let fields = [note.displayTitle, body as String, note.project,
                      note.textDirection.rawValue] + note.tags.sorted()
        let data = (try? JSONEncoder().encode(fields)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum NoteScope: String, CaseIterable, Identifiable {
    case all = "All Notes", active = "Active", archive = "Archive", trash = "Trash"
    var id: Self { self }
    var title: String {
        switch self {
        case .all: L10n.text("organize.scope.all")
        case .active: L10n.text("organize.scope.active")
        case .archive: L10n.text("organize.scope.archive")
        case .trash: L10n.text("organize.scope.trash")
        }
    }
}

enum NoteSort: String, CaseIterable, Identifiable {
    case manual, modified, created, title
    var id: Self { self }
    var title: String { L10n.text("organize.sort.\(rawValue)") }
}

struct NoteQuery {
    var scope: NoteScope = .all
    var text = ""
    var project: String? = nil
    var tag: String? = nil
    var color: Int? = nil
    var sort: NoteSort = .manual

    func results(in notes: [Note]) -> [Note] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        return notes.filter { n in
            switch scope {
            case .all: guard !n.isTrashed else { return false }
            case .active: guard !n.isTrashed && !n.archived else { return false }
            case .archive: guard !n.isTrashed && n.archived else { return false }
            case .trash: guard n.isTrashed else { return false }
            }
            if let project, n.project != project { return false }
            if let tag, !n.tags.contains(where: { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }) { return false }
            if let color, n.color != color { return false }
            let searchable = ([n.displayTitle, NoteFormatting.plainText(n.body), n.project] + n.tags).joined(separator: "\n")
            return words.allSatisfy { searchable.localizedCaseInsensitiveContains($0) }
        }.sorted { a, b in
            switch sort {
            case .manual:
                if scope == .trash, a.deletedAt != b.deletedAt { return a.deletedAt! > b.deletedAt! }
                if a.order != b.order { return a.order < b.order }
            case .modified: if a.modified != b.modified { return a.modified > b.modified }
            case .created: if a.created != b.created { return a.created > b.created }
            case .title:
                let order = a.displayTitle.localizedStandardCompare(b.displayTitle)
                if order != .orderedSame { return order == .orderedAscending }
            }
            return a.id < b.id
        }
    }
}
