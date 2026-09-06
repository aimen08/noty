import Foundation

/// One pass's view of the sync folder. Listing is cheap and reading is not, so
/// a scan carries dates only; contents are fetched on demand.
struct FolderScan: Equatable {
    /// Documents whose contents are available, and when each last changed.
    var documents: [String: Date] = [:]
    /// Documents that exist but whose contents are not here: an iCloud
    /// placeholder still in the cloud, or a read that failed. The notes behind
    /// these names must be left strictly alone — absence of contents is not
    /// evidence of deletion.
    var unresolved: Set<String> = []

    /// Every name the folder holds, readable or not. Filename allocation has to
    /// avoid all of them, not only the ones that could be read.
    var allNames: Set<String> { Set(documents.keys).union(unresolved) }
}

/// Everything a sync pass needs from the file system, behind a protocol so the
/// runner can be driven in tests with no iCloud, no home directory and no clock.
protocol SyncFolderGateway {
    var isAvailable: Bool { get }
    @discardableResult func ensureFolder() -> Bool
    func scan() -> FolderScan
    func read(_ fileName: String) -> String?
    func modificationDate(of fileName: String) -> Date?
    @discardableResult func write(_ text: String, named fileName: String) -> Bool
    @discardableResult func remove(_ fileName: String) -> Bool
    /// Conflict copies go somewhere a note filename can never reach.
    @discardableResult func writeConflict(_ text: String, named fileName: String) -> Bool
}

/// Everything a sync pass needs from the note store.
protocol NoteStoring: AnyObject {
    var notes: [Note] { get }
    var active: [Note] { get }
    func note(id: String) -> Note?
    func absorb(_ note: Note)
    func delete(id: String)
}

extension NoteStore: NoteStoring {}

/// The production gateway: the real iCloud Drive folder.
struct CloudFolderGateway: SyncFolderGateway {
    var isAvailable: Bool { CloudFolder.isAvailable }

    @discardableResult
    func ensureFolder() -> Bool { CloudFolder.ensureFolder() }

    func scan() -> FolderScan { CloudFolder.scan() }

    func read(_ fileName: String) -> String? {
        CloudFolder.read(CloudFolder.url.appendingPathComponent(fileName))
    }

    func modificationDate(of fileName: String) -> Date? {
        CloudFolder.modificationDate(of: CloudFolder.url.appendingPathComponent(fileName))
    }

    @discardableResult
    func write(_ text: String, named fileName: String) -> Bool {
        CloudFolder.write(text, to: CloudFolder.url.appendingPathComponent(fileName))
    }

    @discardableResult
    func remove(_ fileName: String) -> Bool {
        CloudFolder.remove(CloudFolder.url.appendingPathComponent(fileName))
    }

    @discardableResult
    func writeConflict(_ text: String, named fileName: String) -> Bool {
        CloudFolder.writeConflict(text, named: fileName)
    }
}
