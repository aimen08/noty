import Foundation
import SwiftUI
import AppKit
import CryptoKit
import Darwin

// MARK: - Paths

enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Noty", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    static var db: URL { support.appendingPathComponent("notes.db") }
    static var key: URL { support.appendingPathComponent("note.key") }
}

// MARK: - Crypto (AES-GCM for note bodies)

enum PersistenceError: LocalizedError {
    case invalidKey, missingKey, corruptBody, database(String), invalidColor

    var errorDescription: String? {
        switch self {
        case .invalidKey: return L10n.text("storage.invalid_key")
        case .missingKey: return L10n.text("storage.missing_key")
        case .corruptBody: return L10n.text("storage.corrupt_body")
        case .database(let message): return message
        case .invalidColor: return L10n.text("storage.invalid_color")
        }
    }
}

/// Never replace an existing key or accept a key that could not be persisted.
final class Crypto {
    private let keyURL: URL
    private let allowCreation: Bool
    private var cachedKey: SymmetricKey?

    init(keyURL: URL, allowCreation: Bool) {
        self.keyURL = keyURL
        self.allowCreation = allowCreation
    }

    private func key() throws -> SymmetricKey {
        if let cachedKey { return cachedKey }
        let data: Data
        do {
            data = try Data(contentsOf: keyURL)
        } catch let error as NSError {
            guard error.domain == NSCocoaErrorDomain,
                  error.code == NSFileReadNoSuchFileError else { throw error }
            guard allowCreation else { throw PersistenceError.missingKey }
            let generated = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            // Write privately, sync, then install without replacement. Other processes
            // must never see a partially written key, even if creation fails.
            let temporary = keyURL.deletingLastPathComponent()
                .appendingPathComponent(".note-key-\(UUID().uuidString)")
            let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            defer { Darwin.close(fd); Darwin.unlink(temporary.path) }
            let count = generated.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard count == generated.count, fsync(fd) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno == 0 ? EIO : errno))
            }
            guard Darwin.link(temporary.path, keyURL.path) == 0 else {
                if errno == EEXIST { return try readExistingKey() }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            data = generated
        }
        guard data.count == 32 else { throw PersistenceError.invalidKey }
        let key = SymmetricKey(data: data)
        cachedKey = key
        return key
    }

    private func readExistingKey() throws -> SymmetricKey {
        let data = try Data(contentsOf: keyURL)
        guard data.count == 32 else { throw PersistenceError.invalidKey }
        let key = SymmetricKey(data: data)
        cachedKey = key
        return key
    }

    func seal(_ text: String) throws -> Data {
        let box = try AES.GCM.seal(Data(text.utf8), using: key())
        guard let combined = box.combined else { throw PersistenceError.corruptBody }
        return combined
    }

    func open(_ data: Data) throws -> String {
        let key = try key()
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            let plain = try AES.GCM.open(box, using: key)
            guard let text = String(data: plain, encoding: .utf8) else {
                throw PersistenceError.corruptBody
            }
            return text
        } catch { throw PersistenceError.corruptBody }
    }
}

// MARK: - Palette

struct NoteColor {
    let name: String       // stable English archive value
    let paper: Color      // note body background
    let dash: Color       // saturated edge dash / colour bar
    let ink: Color        // text colour on paper

    /// Slightly deeper than a highlighter pastel, so a note reads as paper with
    /// colour in it rather than a tinted white rectangle.
    static let all: [NoteColor] = [
        NoteColor(name: "Lemon",  paper: hex(0xFCE795), dash: hex(0xE0AD08), ink: hex(0x3A3008)),
        NoteColor(name: "Peach",  paper: hex(0xFBCFA6), dash: hex(0xE2762A), ink: hex(0x422413)),
        NoteColor(name: "Rose",   paper: hex(0xFAC4D1), dash: hex(0xDC4570), ink: hex(0x40161F)),
        NoteColor(name: "Lilac",  paper: hex(0xD9C7FA), dash: hex(0x7C4DEE), ink: hex(0x2A1B44)),
        NoteColor(name: "Sky",    paper: hex(0xBEDDFA), dash: hex(0x2280D6), ink: hex(0x13293A)),
        NoteColor(name: "Mint",   paper: hex(0xB4E8D0), dash: hex(0x0E9B6E), ink: hex(0x0F2E23)),
        NoteColor(name: "Sand",   paper: hex(0xE3D3B4), dash: hex(0xA37B3C), ink: hex(0x372C18)),
        NoteColor(name: "Slate",  paper: hex(0xCBD6E2), dash: hex(0x4E6579), ink: hex(0x1A242E)),
    ]

    static func at(_ i: Int) -> NoteColor { all[((i % all.count) + all.count) % all.count] }

    var localizedName: String {
        L10n.text("color.\(name.lowercased())")
    }

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
    let name: String          // stable face name; localizedName is shown in UI
    let body: String          // PostScript name, "" for the system font
    let tab: String           // heavier cut used on the tab labels
    let bump: CGFloat         // size nudge so faces look the same size as each other

    var localizedName: String {
        body.isEmpty ? L10n.text("font.system") : name
    }
}

enum Ink {
    /// Faces that suit a note. Filtered to what is actually installed, so the
    /// menu never offers something that would silently fall back.
    static let allFaces: [NoteFace] = [
        NoteFace(name: "System",       body: "",                     tab: "",                     bump: 0),
        NoteFace(name: "Noteworthy",   body: "Noteworthy-Light",     tab: "Noteworthy-Bold",      bump: 1.5),
        NoteFace(name: "Bradley Hand", body: "BradleyHandITCTT-Bold", tab: "BradleyHandITCTT-Bold", bump: 1.5),
        NoteFace(name: "Marker Felt",  body: "MarkerFelt-Thin",      tab: "MarkerFelt-Wide",      bump: 1),
        NoteFace(name: "Chalkboard",   body: "ChalkboardSE-Light",   tab: "ChalkboardSE-Bold",    bump: 0),
        NoteFace(name: "Avenir Next",  body: "AvenirNext-Regular",   tab: "AvenirNext-DemiBold",  bump: 0),
        NoteFace(name: "New York",     body: "NewYork-Regular",      tab: "NewYork-Semibold",     bump: 0),
        NoteFace(name: "Georgia",      body: "Georgia",              tab: "Georgia-Bold",         bump: 0),
        NoteFace(name: "Menlo",        body: "Menlo-Regular",        tab: "Menlo-Bold",           bump: -1),
    ]

    /// Installed faces do not change while the app runs, and this is asked for on
    /// every text render — resolving it each time cost nine font lookups a call.
    static let faces: [NoteFace] =
        allFaces.filter { $0.body.isEmpty || NSFont(name: $0.body, size: 12) != nil }

    private static var faceCache: (name: String, face: NoteFace)?

    static var face: NoteFace {
        let want = Settings.noteFontName
        if let cached = faceCache, cached.name == want { return cached.face }
        let resolved = faces.first { $0.body == want } ?? faces[0]
        faceCache = (want, resolved)
        return resolved
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
    /// Labels scale with the deck, so a bigger tab carries a bigger title rather
    /// than more empty paper. Layout measures the strip with this very font, so
    /// the two cannot drift apart.
    static var tabSize: CGFloat { 9.5 * DeckGeom.scale }
    static var tabTracking: CGFloat { 0.1 * DeckGeom.scale }

    /// For measuring — layout sizes each tab's strip to the longest label.
    static var tabNSFont: NSFont {
        let f = face
        guard !f.tab.isEmpty, let font = NSFont(name: f.tab, size: tabSize + f.bump) else {
            return .systemFont(ofSize: tabSize - 0.5, weight: .semibold)
        }
        return font
    }

    /// The body face as a SwiftUI font. Falls back to the system font by name,
    /// which `Font.custom` cannot express for the system face.
    static func bodyFont(_ size: CGFloat) -> Font {
        let f = face
        guard !f.body.isEmpty, NSFont(name: f.body, size: size) != nil else {
            return .system(size: size)
        }
        return .custom(f.body, size: size + f.bump)
    }

    static var tabFont: Font {
        let f = face
        guard !f.tab.isEmpty, NSFont(name: f.tab, size: tabSize) != nil else {
            return .system(size: tabSize - 0.5, weight: .semibold)
        }
        return .custom(f.tab, size: tabSize + f.bump)
    }
}

// MARK: - Model

enum NoteTextDirection: String, Codable, CaseIterable, Identifiable {
    case automatic
    case leftToRight
    case rightToLeft

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic:   L10n.text("direction.automatic")
        case .leftToRight: L10n.text("direction.left_to_right")
        case .rightToLeft: L10n.text("direction.right_to_left")
        }
    }

    var symbol: String? {
        switch self {
        case .automatic:   nil
        case .leftToRight: "text.alignleft"
        case .rightToLeft: "text.alignright"
        }
    }

    var writingDirection: NSWritingDirection {
        switch self {
        case .automatic:   .natural
        case .leftToRight: .leftToRight
        case .rightToLeft: .rightToLeft
        }
    }

    var alignment: NSTextAlignment {
        switch self {
        case .automatic:   .natural
        case .leftToRight: .left
        case .rightToLeft: .right
        }
    }

    var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.baseWritingDirection = writingDirection
        style.alignment = alignment
        return style
    }

    /// Resolve Automatic from the first strong character in a paragraph.
    /// AppKit's `.natural` alignment follows the app's locale on macOS rather
    /// than reliably aligning each paragraph from its contents, so the editor
    /// stores an explicit paragraph direction after inspecting the text.
    func paragraphStyle(for paragraph: String) -> NSParagraphStyle {
        guard self == .automatic else { return paragraphStyle }
        let direction = Self.firstStrongDirection(in: paragraph) ?? .leftToRight
        let style = NSMutableParagraphStyle()
        style.baseWritingDirection = direction
        style.alignment = direction == .rightToLeft ? .right : .left
        return style
    }

    static func firstStrongDirection(in text: String) -> NSWritingDirection? {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x200E: return .leftToRight  // LEFT-TO-RIGHT MARK
            case 0x061C, 0x200F: return .rightToLeft // ARABIC/RIGHT-TO-LEFT MARK
            default: break
            }

            // Punctuation, whitespace, emoji, combining marks, and digits are
            // neutral here; they must not decide the paragraph's direction.
            guard scalar.properties.isAlphabetic else { continue }
            return Self.isRightToLeftLetter(scalar.value) ? .rightToLeft : .leftToRight
        }
        return nil
    }

    private static func isRightToLeftLetter(_ value: UInt32) -> Bool {
        switch value {
        case 0x0590...0x08FF,   // Hebrew, Arabic, Syriac, Thaana, N'Ko, etc.
             0xFB1D...0xFDFF,   // Hebrew and Arabic presentation forms
             0xFE70...0xFEFF,   // Arabic presentation forms B
             0x10800...0x10FFF, // historic right-to-left scripts
             0x1E800...0x1EEFF: // Mende, Adlam, Arabic mathematical letters
            true
        default:
            false
        }
    }
}

struct Note: Identifiable, Hashable {
    var id: String = UUID().uuidString
    var title: String = ""
    var body: String = ""
    var color: Int = 0
    var created: Date = Date()
    var modified: Date = Date()
    var archived: Bool = false
    var pinned: Bool = false
    var textDirection: NoteTextDirection = .automatic
    var order: Double = 0

    var palette: NoteColor { NoteColor.at(color) }

    var hasCustomTitle: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Title shown in the fan / lists, derived from the first non-empty line.
    static func derivedTitle(from body: String) -> String {
        let line = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var clean = line.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "^#{1,6}\\s*", with: "", options: .regularExpression)
        clean = Tasks.stripped(clean)
        if clean.isEmpty { return "" }
        return clean.count > 60 ? String(clean.prefix(60)) + "…" : clean
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let derived = Self.derivedTitle(from: body)
        return derived.isEmpty ? L10n.text("note.untitled") : derived
    }

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

    /// Collapsed snippet used as list subtitle.
    /// If the note has an independent custom title, the first line of the body is
    /// part of the content and included in the preview; otherwise the first line
    /// is skipped because it already serves as the title.
    var preview: String {
        let lines = body.split(whereSeparator: \.isNewline).map(String.init)
        let rest = (hasCustomTitle ? lines : Array(lines.dropFirst()))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
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
        text.replacingOccurrences(of: "(?m)^([\\t ]*)[-*][\\t ]+\\[ \\][\\t ]+",
                                  with: "$1" + openPrefix, options: .regularExpression)
            .replacingOccurrences(of: "(?m)^([\\t ]*)[-*][\\t ]+\\[[xX]\\][\\t ]+",
                                  with: "$1" + donePrefix, options: .regularExpression)
    }

    static func toMarkdown(_ text: String) -> String {
        text.replacingOccurrences(of: "(?m)^([\\t ]*)☐ ", with: "$1- [ ] ",
                                  options: .regularExpression)
            .replacingOccurrences(of: "(?m)^([\\t ]*)☑ ", with: "$1- [x] ",
                                  options: .regularExpression)
    }
}

// MARK: - Formatting

enum Fmt {
    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
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
        if Date().timeIntervalSince(d) < 60 { return L10n.text("date.just_now") }
        return relative.localizedString(for: d, relativeTo: Date())
    }
}
