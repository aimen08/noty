import Foundation
import SwiftUI
import AppKit
import CryptoKit
import Security

// MARK: - Paths

enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Noty", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    static var db: URL { support.appendingPathComponent("notes.db") }
    static var legacyKey: URL { support.appendingPathComponent("note.key") }
}

// MARK: - Crypto (AES-GCM for note bodies)

private enum KeychainStore {
    private static let service = "app.noty.Noty"
    private static let account = "note-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func save(_ data: Data) -> Bool {
        let status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

enum Crypto {
    private static let key: SymmetricKey = {
        if let d = KeychainStore.load() {
            guard d.count == 32 else {
                preconditionFailure("Noty: invalid note key in Keychain")
            }
            try? FileManager.default.removeItem(at: Paths.legacyKey)
            return SymmetricKey(data: d)
        }
        if let legacy = try? Data(contentsOf: Paths.legacyKey), legacy.count == 32 {
            guard KeychainStore.save(legacy) else {
                preconditionFailure("Noty: cannot migrate note key to Keychain")
            }
            try? FileManager.default.removeItem(at: Paths.legacyKey)
            return SymmetricKey(data: legacy)
        }
        let k = SymmetricKey(size: .bits256)
        let d = k.withUnsafeBytes { Data($0) }
        guard KeychainStore.save(d) else {
            preconditionFailure("Noty: cannot persist note key in Keychain")
        }
        return k
    }()

    static func seal(_ text: String) -> Data {
        guard let box = try? AES.GCM.seal(Data(text.utf8), using: key),
              let combined = box.combined else { return Data() }
        return combined
    }

    static func open(_ data: Data) -> String {
        guard !data.isEmpty,
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { return "" }
        return String(decoding: plain, as: UTF8.self)
    }
}

// MARK: - Palette

struct NoteColor {
    let name: String
    let paper: Color      // note body background
    let dash: Color       // saturated edge dash / colour bar
    let ink: Color        // text colour on paper

    /// Slightly deeper than a highlighter pastel, so a note reads as paper with
    /// colour in it rather than a tinted white rectangle.
    static let all: [NoteColor] = [
        NoteColor(name: "Лимонный",    paper: hex(0xFCE795), dash: hex(0xE0AD08), ink: hex(0x3A3008)),
        NoteColor(name: "Персиковый",  paper: hex(0xFBCFA6), dash: hex(0xE2762A), ink: hex(0x422413)),
        NoteColor(name: "Розовый",     paper: hex(0xFAC4D1), dash: hex(0xDC4570), ink: hex(0x40161F)),
        NoteColor(name: "Сиреневый",   paper: hex(0xD9C7FA), dash: hex(0x7C4DEE), ink: hex(0x2A1B44)),
        NoteColor(name: "Небесный",    paper: hex(0xBEDDFA), dash: hex(0x2280D6), ink: hex(0x13293A)),
        NoteColor(name: "Мятный",      paper: hex(0xB4E8D0), dash: hex(0x0E9B6E), ink: hex(0x0F2E23)),
        NoteColor(name: "Песочный",    paper: hex(0xE3D3B4), dash: hex(0xA37B3C), ink: hex(0x372C18)),
        NoteColor(name: "Серо-синий",  paper: hex(0xCBD6E2), dash: hex(0x4E6579), ink: hex(0x1A242E)),
    ]

    static func at(_ i: Int) -> NoteColor { all[((i % all.count) + all.count) % all.count] }

    private static func hex(_ v: UInt32) -> Color {
        Color(.sRGB,
              red:   Double((v >> 16) & 0xFF) / 255,
              green: Double((v >> 8) & 0xFF) / 255,
              blue:  Double(v & 0xFF) / 255,
              opacity: 1)
    }
}

// MARK: - Type

/// One entry per face offered for note bodies.
struct NoteFace {
    let name: String          // shown in the menu
    let body: String          // PostScript name, "" for the system font
    let tab: String           // heavier cut used on the tab labels
    let bump: CGFloat         // size nudge so faces look the same size as each other
}

enum Ink {
    /// Faces that suit a note. Filtered to what is actually installed, so the
    /// menu never offers something that would silently fall back.
    static let allFaces: [NoteFace] = [
        NoteFace(name: "Системный",    body: "",                     tab: "",                     bump: 0),
        NoteFace(name: "Noteworthy",   body: "Noteworthy-Light",     tab: "Noteworthy-Bold",      bump: 1.5),
        NoteFace(name: "Bradley Hand", body: "BradleyHandITCTT-Bold", tab: "BradleyHandITCTT-Bold", bump: 1.5),
        NoteFace(name: "Marker Felt",  body: "MarkerFelt-Thin",      tab: "MarkerFelt-Wide",      bump: 1),
        NoteFace(name: "Chalkboard",   body: "ChalkboardSE-Light",   tab: "ChalkboardSE-Bold",    bump: 0),
        NoteFace(name: "Avenir Next",  body: "AvenirNext-Regular",   tab: "AvenirNext-DemiBold",  bump: 0),
        NoteFace(name: "New York",     body: "NewYork-Regular",      tab: "NewYork-Semibold",     bump: 0),
        NoteFace(name: "Georgia",      body: "Georgia",              tab: "Georgia-Bold",         bump: 0),
        NoteFace(name: "Menlo",        body: "Menlo-Regular",        tab: "Menlo-Bold",           bump: -1),
    ]

    static var faces: [NoteFace] {
        allFaces.filter { $0.body.isEmpty || NSFont(name: $0.body, size: 12) != nil }
    }

    static var face: NoteFace {
        let want = Settings.noteFontName
        return faces.first { $0.body == want } ?? faces[0]
    }

    /// The hand (or face) note bodies are set in.
    static func body(_ size: CGFloat) -> NSFont {
        let f = face
        guard !f.body.isEmpty, let font = NSFont(name: f.body, size: size + f.bump) else {
            return .systemFont(ofSize: size)
        }
        return font
    }

    // Tab labels use the same face a shade bolder, so they hold up turned on
    // their side at this size.
    static let tabSize: CGFloat = 9.5
    static let tabTracking: CGFloat = 0.1

    /// For measuring — layout sizes each tab's strip to the longest label.
    static var tabNSFont: NSFont {
        let f = face
        guard !f.tab.isEmpty, let font = NSFont(name: f.tab, size: tabSize + f.bump) else {
            return .systemFont(ofSize: 9, weight: .semibold)
        }
        return font
    }

    static var tabFont: Font {
        let f = face
        guard !f.tab.isEmpty, NSFont(name: f.tab, size: tabSize) != nil else {
            return .system(size: 9, weight: .semibold)
        }
        return .custom(f.tab, size: tabSize + f.bump)
    }
}

// MARK: - Model

struct Note: Identifiable, Hashable {
    var id: String = UUID().uuidString
    var title: String = ""
    var body: String = ""
    var color: Int = 0
    var created: Date = Date()
    var modified: Date = Date()
    var archived: Bool = false
    var pinned: Bool = false
    var order: Double = 0

    var palette: NoteColor { NoteColor.at(color) }

    /// Title shown in the fan / lists, derived from the first non-empty line.
    static func derivedTitle(from body: String) -> String {
        let line = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var clean = line.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "^#{1,6}\\s*", with: "", options: .regularExpression)
        clean = Tasks.stripped(clean)
        if clean.isEmpty { return "" }
        return clean.count > 60 ? String(clean.prefix(60)) + "…" : clean
    }

    var displayTitle: String { title.isEmpty ? "Новая заметка" : title }

    /// Completed / total, or nil when the note holds no tasks.
    var taskProgress: (done: Int, total: Int)? {
        var done = 0, total = 0
        for line in body.split(whereSeparator: \.isNewline) {
            switch Tasks.marker(of: line) {
            case Tasks.done: done += 1; total += 1
            case Tasks.open: total += 1
            default: break
            }
        }
        return total > 0 ? (done, total) : nil
    }

    /// Second line onwards, collapsed — used as list subtitle.
    var preview: String {
        let lines = body.split(whereSeparator: \.isNewline).map(String.init)
        let rest = lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return rest.count > 120 ? String(rest.prefix(120)) + "…" : rest
    }
}

// MARK: - Tasks

/// Checkbox tasks are stored inline in the note body as ☐ / ☑ line prefixes, so a
/// note is still plain text and exports cleanly to Markdown task syntax.
enum Tasks {
    static let open: Character = "\u{2610}"    // ☐
    static let done: Character = "\u{2611}"    // ☑
    static let openPrefix = "\u{2610} "
    static let donePrefix = "\u{2611} "

    static func marker(of line: some StringProtocol) -> Character? {
        guard let f = line.first, f == open || f == done else { return nil }
        return f
    }

    static func isTask(_ line: some StringProtocol) -> Bool { marker(of: line) != nil }

    /// Strip the marker for display in lists and titles.
    static func stripped(_ line: some StringProtocol) -> String {
        guard isTask(line) else { return String(line) }
        return String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    /// Markdown task syntax in, ☐/☑ out.
    static func fromMarkdown(_ text: String) -> String {
        text.replacingOccurrences(of: "^(\\s*)[-*]\\s+\\[[ ]\\]\\s+",
                                  with: "$1" + openPrefix,
                                  options: [.regularExpression])
            .replacingOccurrences(of: "^(\\s*)[-*]\\s+\\[[xX]\\]\\s+",
                                  with: "$1" + donePrefix,
                                  options: [.regularExpression])
    }

    /// ☐/☑ out, Markdown task syntax in.
    static func toMarkdown(_ text: String) -> String {
        text.replacingOccurrences(of: openPrefix, with: "- [ ] ")
            .replacingOccurrences(of: donePrefix, with: "- [x] ")
    }
}

// MARK: - Formatting

enum Fmt {
    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.unitsStyle = .abbreviated
        return f
    }()

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

    static func ago(_ d: Date) -> String {
        if Date().timeIntervalSince(d) < 60 { return "только что" }
        return relative.localizedString(for: d, relativeTo: Date())
    }
}
