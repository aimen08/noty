import Foundation

/// One-shot hand-off between the old and new process on a language-change
/// relaunch. The new instance reads it at launch and deletes it, so a stale
/// file can never resurrect old state later.
struct ReloadResume: Codable {
    var noteID: String?
    var displayID: UInt32?
    var settingsOpen: Bool

    var open: Bool { noteID != nil || settingsOpen }

    static let url = Paths.support.appendingPathComponent("resume.json")

    static func save(_ resume: ReloadResume) {
        do {
            try JSONEncoder().encode(resume).write(to: url, options: [.atomic])
        } catch {
            NSLog("Noty: could not write reload resume — \(error.localizedDescription)")
        }
    }

    static func loadAndClear() -> ReloadResume? {
        let resume = (try? JSONDecoder().decode(ReloadResume.self, from: Data(contentsOf: url)))
        try? FileManager.default.removeItem(at: url)
        return resume
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
