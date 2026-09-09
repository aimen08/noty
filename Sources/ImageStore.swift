import Foundation
import AppKit

/// Images referenced from note bodies live as plain files under
/// `Application Support/Noty/Images`, one `<UUID>.png` (or original ext) per
/// image, with the note text holding only a `![image](noty-img://<UUID>)`
/// token. Keeping bytes out of SQLite keeps the encrypted database small and
/// lets a single image be shared across notes.
enum ImageStore {
    static let scheme = "noty-img"

    /// Created lazily so an app that never embeds an image never makes the folder.
    static let directory: URL = {
        let dir = Paths.support.appendingPathComponent("Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Ids come from note text, which the user can type freely — anything that
    /// is not UUID-ish must never reach the filesystem, or a crafted token
    /// could point outside the Images folder.
    private static let idAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")

    private static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy { idAllowed.contains($0) }
    }

    private static func isValidExt(_ ext: String) -> Bool {
        !ext.isEmpty && ext.count <= 10 && ext.allSatisfy { $0.isLetter || $0.isNumber }
    }

    private static func fileURL(id: String, ext: String = "png") -> URL {
        directory.appendingPathComponent("\(id).\(ext)")
    }

    /// Find an image file regardless of extension (imports may keep jpg etc.).
    private static func existingFileURL(id: String) -> URL? {
        guard isValidID(id) else { return nil }
        let plain = fileURL(id: id)
        if FileManager.default.fileExists(atPath: plain.path) { return plain }
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        let prefix = id + "."
        guard let name = contents.first(where: { $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains(".") }) else { return nil }
        return directory.appendingPathComponent(name)
    }

    // MARK: - Saving

    /// Absurdly large paste sources (screenshots at 5K, camera dumps) would
    /// balloon the folder; anything past this size is scaled down before PNG.
    private static let maxSide: CGFloat = 2048

    static func save(image: NSImage) -> String? {
        var source = image
        let size = image.size
        let longest = max(size.width, size.height)
        if longest > maxSide, longest > 0 {
            let scale = maxSide / longest
            let scaled = NSSize(width: floor(size.width * scale), height: floor(size.height * scale))
            let down = NSImage(size: scaled)
            down.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: scaled),
                       from: NSRect(origin: .zero, size: size),
                       operation: .sourceOver, fraction: 1)
            down.unlockFocus()
            source = down
        }
        guard let tiff = source.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return save(data: png, ext: "png")
    }

    static func save(data: Data, ext: String) -> String? {
        let ext = ext.lowercased()
        guard !data.isEmpty, isValidExt(ext) else { return nil }
        let id = UUID().uuidString
        do {
            try data.write(to: fileURL(id: id, ext: ext), options: [.atomic])
            return id
        } catch {
            return nil
        }
    }

    // MARK: - Tokens

    /// The full markdown token line (no trailing newline). Integral widths are
    /// written without decimals so the note text stays tidy.
    static func token(id: String, width: CGFloat?) -> String {
        guard let w = width, w > 0 else { return "![image](\(scheme)://\(id))" }
        let s: String
        if w.rounded() == w {
            s = String(Int(w))
        } else {
            s = String(format: "%.1f", Double(w))
        }
        return "![image|\(s)](\(scheme)://\(id))"
    }

    /// One shared regex; tokens are matched over the text as NSString so the
    /// reported NSRanges line up with NSTextStorage indexing.
    private static let tokenRegex: NSRegularExpression = {
        // width group first, id group second
        let pattern = "!\\[image(?:\\|([0-9]+(?:\\.[0-9]+)?))?\\]\\(\(scheme)://([A-Za-z0-9-]+)\\)"
        // try! is safe: the pattern is a compile-time constant.
        return try! NSRegularExpression(pattern: pattern)
    }()

    static func tokens(in text: String) -> [(id: String, width: CGFloat?, range: NSRange)] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        return tokenRegex.matches(in: text, range: full).map { m in
            var width: CGFloat?
            let wr = m.range(at: 1)
            if wr.location != NSNotFound { width = CGFloat(Double(ns.substring(with: wr)) ?? 0) }
            return (id: ns.substring(with: m.range(at: 2)), width: width, range: m.range)
        }
    }

    static func referencedIDs(in text: String) -> [String] {
        tokens(in: text).map(\.id)
    }

    // MARK: - Loading

    /// The editor asks for images on every style pass; decoding PNGs each time
    /// would hitch typing, so decoded NSImages are cached by id. NSCache evicts
    /// under memory pressure, which a plain dictionary would not.
    private static let cache = NSCache<NSString, NSImage>()

    static func image(id: String) -> NSImage? {
        let key = id as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let url = existingFileURL(id: id), let img = NSImage(contentsOf: url) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }

    /// Raw file bytes for export; not cached, since export is rare and the
    /// caller usually wants the original encoding rather than a re-encoded PNG.
    static func data(id: String) -> Data? {
        guard let url = existingFileURL(id: id) else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: - Deleting / listing

    static func delete(ids: [String]) {
        for id in ids {
            cache.removeObject(forKey: id as NSString)
            guard let url = existingFileURL(id: id) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func allIDs() -> [String] {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return contents.compactMap { name in
            let id = (name as NSString).deletingPathExtension
            return isValidID(id) ? id : nil
        }
    }
}
