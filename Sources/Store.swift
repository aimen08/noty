import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite-backed note storage. Bodies are AES-GCM sealed; title/colour/dates stay
/// plaintext so lists can render without unsealing every row.
final class Store {
    private var db: OpaquePointer?

    init(dbURL: URL = Paths.db) {
        if sqlite3_open_v2(dbURL.path, &db,
                           SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                           nil) != SQLITE_OK {
            NSLog("Noty: cannot open db at \(dbURL.path)")
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        exec("""
        CREATE TABLE IF NOT EXISTS notes (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL DEFAULT '',
          body BLOB NOT NULL,
          color INTEGER NOT NULL DEFAULT 0,
          created REAL NOT NULL,
          modified REAL NOT NULL,
          archived INTEGER NOT NULL DEFAULT 0,
          sort_order REAL NOT NULL DEFAULT 0,
          pinned INTEGER NOT NULL DEFAULT 0,
          text_direction TEXT NOT NULL DEFAULT 'automatic'
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_notes_archived ON notes(archived, sort_order);")
        migrate()
    }

    /// Adds columns introduced after a database was first created. Checked rather
    /// than attempted-and-ignored, so a real failure still shows up in the log.
    private func migrate() {
        var existing = Set<String>()
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(notes);", -1, &st, nil) == SQLITE_OK {
            while sqlite3_step(st) == SQLITE_ROW {
                if let c = sqlite3_column_text(st, 1) { existing.insert(String(cString: c)) }
            }
        }
        sqlite3_finalize(st)
        if !existing.contains("pinned") {
            exec("ALTER TABLE notes ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;")
            NSLog("Noty: migrated notes table — added pinned")
        }
        if !existing.contains("text_direction") {
            exec("ALTER TABLE notes ADD COLUMN text_direction TEXT NOT NULL DEFAULT 'automatic';")
            NSLog("Noty: migrated notes table — added text direction")
        }
    }

    deinit { if let db { sqlite3_close_v2(db) } }

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK, let err {
            NSLog("Noty sql: \(String(cString: err))")
            sqlite3_free(err)
        }
    }

    // MARK: Reads

    func load() -> [Note] {
        var out: [Note] = []
        var st: OpaquePointer?
        let sql = "SELECT id,title,body,color,created,modified,archived,sort_order,pinned,text_direction FROM notes ORDER BY sort_order ASC;"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return out }
        defer { sqlite3_finalize(st) }
        while sqlite3_step(st) == SQLITE_ROW {
            var n = Note()
            n.id = String(cString: sqlite3_column_text(st, 0))
            n.title = sqlite3_column_text(st, 1).map { String(cString: $0) } ?? ""
            if let blob = sqlite3_column_blob(st, 2) {
                let len = Int(sqlite3_column_bytes(st, 2))
                n.body = Crypto.open(Data(bytes: blob, count: len))
            }
            n.color = Int(sqlite3_column_int(st, 3))
            n.created = Date(timeIntervalSince1970: sqlite3_column_double(st, 4))
            n.modified = Date(timeIntervalSince1970: sqlite3_column_double(st, 5))
            n.archived = sqlite3_column_int(st, 6) != 0
            n.order = sqlite3_column_double(st, 7)
            n.pinned = sqlite3_column_int(st, 8) != 0
            let rawDirection = sqlite3_column_text(st, 9).map { String(cString: $0) }
            n.textDirection = rawDirection.flatMap(NoteTextDirection.init(rawValue:)) ?? .automatic
            out.append(n)
        }
        return out
    }

    // MARK: Writes

    func upsert(_ n: Note) {
        let sql = """
        INSERT INTO notes (id,title,body,color,created,modified,archived,sort_order,pinned,text_direction)
        VALUES (?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          title=excluded.title, body=excluded.body, color=excluded.color,
          modified=excluded.modified, archived=excluded.archived,
          sort_order=excluded.sort_order, pinned=excluded.pinned,
          text_direction=excluded.text_direction;
        """
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        let sealed = Crypto.seal(n.body)
        sqlite3_bind_text(st, 1, n.id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(st, 2, n.title, -1, SQLITE_TRANSIENT)
        _ = sealed.withUnsafeBytes { raw in
            sqlite3_bind_blob(st, 3, raw.baseAddress, Int32(sealed.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_int(st, 4, Int32(n.color))
        sqlite3_bind_double(st, 5, n.created.timeIntervalSince1970)
        sqlite3_bind_double(st, 6, n.modified.timeIntervalSince1970)
        sqlite3_bind_int(st, 7, n.archived ? 1 : 0)
        sqlite3_bind_double(st, 8, n.order)
        sqlite3_bind_int(st, 9, n.pinned ? 1 : 0)
        sqlite3_bind_text(st, 10, n.textDirection.rawValue, -1, SQLITE_TRANSIENT)
        if sqlite3_step(st) != SQLITE_DONE {
            NSLog("Noty: upsert failed — \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    func delete(id: String) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM notes WHERE id=?;", -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_step(st)
    }
}
