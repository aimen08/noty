import Foundation

/// What the last successful sync pass saw, so the next one can tell a local edit
/// from a remote one. Kept beside the database in Application Support — never in
/// the synced folder, where another Mac would fight over it.
struct CloudSyncIndex: Codable {
    struct Entry: Codable, Equatable {
        var fileName: String
        /// The note's `modified` when it was last written out or read in.
        var syncedModified: Date
        /// The file's own modification date at that same moment. This, not the
        /// header, is what detects an edit made by an editor that knows nothing
        /// about Noty's front-matter.
        var fileModified: Date
    }

    var entries: [String: Entry] = [:]      // keyed by note id

    static var defaultURL: URL { Paths.support.appendingPathComponent("cloud-index.json") }

    static func load(from url: URL = CloudSyncIndex.defaultURL) -> CloudSyncIndex {
        guard let data = try? Data(contentsOf: url),
              let index = try? decoder.decode(CloudSyncIndex.self, from: data) else {
            return CloudSyncIndex()
        }
        return index
    }

    func save(to url: URL = CloudSyncIndex.defaultURL) {
        do {
            try Self.encoder.encode(self).write(to: url, options: .atomic)
        } catch {
            NSLog("Noty cloud: cannot save the sync index — \(error.localizedDescription)")
        }
    }

    func id(forFileName name: String) -> String? {
        entries.first { $0.value.fileName == name }?.key
    }

    mutating func record(noteID: String, fileName: String,
                         noteModified: Date, fileModified: Date) {
        entries[noteID] = Entry(fileName: fileName,
                                syncedModified: noteModified,
                                fileModified: fileModified)
    }

    mutating func forget(noteID: String) { entries[noteID] = nil }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
