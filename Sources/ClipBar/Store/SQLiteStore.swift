import Foundation
import SQLite3

/// SQLite-backed persistence for history + pinboards.
///
/// Replaces the single-file store.json: unchanged containers are never
/// rewritten, large text/RTF payloads live in per-clip files under `blobs/`
/// (the database keeps only metadata for them), and WAL mode keeps a crash
/// from losing more than the last transaction. Corrupt databases are
/// quarantined beside the store instead of being silently recreated.
///
/// Layout under the storage directory:
///   history.db / history.db-wal / history.db-shm
///   blobs/<uuid>.txt|.rtf      oversized payloads (> inlineLimit bytes)
final class SQLiteStore {
    static let inlineLimit = 128_000

    struct Snapshot {
        var history: [ClipItem]
        var pinboards: [Pinboard]
    }

    private var db: OpaquePointer?
    private let dbURL: URL
    private let blobsDir: URL

    init?(directory: URL) {
        dbURL = directory.appendingPathComponent("history.db")
        blobsDir = directory.appendingPathComponent("blobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        var handle: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        db = handle
        guard exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=3000;")
            && exec("""
                CREATE TABLE IF NOT EXISTS pinboards(
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, color_hex TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS clips(
                    id TEXT PRIMARY KEY,
                    container TEXT NOT NULL,
                    position INTEGER NOT NULL,
                    type TEXT NOT NULL,
                    text_truncated INTEGER NOT NULL DEFAULT 0,
                    text_value TEXT,
                    text_path TEXT,
                    rtf_blob BLOB,
                    rtf_path TEXT,
                    image_file TEXT, image_hash TEXT,
                    file_urls TEXT, color_hex TEXT,
                    source_bundle TEXT, source_name TEXT, title TEXT,
                    created_at REAL NOT NULL);
                CREATE INDEX IF NOT EXISTS clips_container ON clips(container, position);
                CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
                """) else {
            quarantine(reason: "schema init failed: \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
        // Pre-existing databases gain the column added after v0.3.0.
        _ = exec("ALTER TABLE clips ADD COLUMN text_truncated INTEGER NOT NULL DEFAULT 0;")
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dbURL.path)
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            if let err { sqlite3_free(err) }
            return false
        }
        return true
    }

    /// A database that exists but cannot be opened/initialized is preserved for
    /// inspection as history.db.corrupt-<timestamp> (same policy as the old
    /// JSON store, KNOWN_ISSUES KI-006).
    private func quarantine(reason: String) {
        sqlite3_close(db); db = nil
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let to = dbURL.appendingPathExtension("corrupt-\(stamp)")
        try? FileManager.default.moveItem(at: dbURL, to: to)
        NSLog("ClipBar: history.db quarantined (\(to.lastPathComponent)): \(reason)")
    }

    // MARK: - Read

    func load() -> Snapshot {
        var history: [ClipItem] = []
        var boardsByID: [String: Pinboard] = [:]
        var boardOrder: [String] = []

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, name, color_hex FROM pinboards", -1, &stmt, nil) == SQLITE_OK else {
            return Snapshot(history: [], pinboards: [])
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            boardsByID[id] = Pinboard(id: UUID(uuidString: id) ?? UUID(),
                                      name: String(cString: sqlite3_column_text(stmt, 1)),
                                      colorHex: String(cString: sqlite3_column_text(stmt, 2)))
            boardOrder.append(id)
        }
        sqlite3_finalize(stmt)

        guard sqlite3_prepare_v2(db, """
            SELECT id, container, type, text_truncated, text_value, text_path, rtf_blob, rtf_path,
                   image_file, image_hash, file_urls, color_hex,
                   source_bundle, source_name, title, created_at
            FROM clips ORDER BY container, position
            """, -1, &stmt, nil) == SQLITE_OK else {
            return Snapshot(history: [], pinboards: [])
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            func optText(_ i: Int32) -> String? {
                sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, i))
            }
            func optBlob(_ i: Int32) -> Data? {
                guard sqlite3_column_type(stmt, i) != SQLITE_NULL,
                      let bytes = sqlite3_column_blob(stmt, i) else { return nil }
                return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, i)))
            }
            func readBlobFile(_ i: Int32) -> Data? {
                optText(i).flatMap { try? Data(contentsOf: blobsDir.appendingPathComponent($0)) }
            }
            let container = String(cString: sqlite3_column_text(stmt, 1))
            let truncated = sqlite3_column_int(stmt, 3) != 0
            let item = ClipItem(
                id: UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) ?? UUID(),
                type: ClipType(rawValue: String(cString: sqlite3_column_text(stmt, 2))) ?? .text,
                text: optText(4) ?? readBlobFile(5).flatMap { String(data: $0, encoding: .utf8) },
                rtfData: optBlob(6) ?? readBlobFile(7),
                imageFileName: optText(8),
                imageHash: optText(9),
                fileURLs: optText(10).map { $0.split(separator: "\u{1f}").map(String.init) } ?? [],
                colorHex: optText(11),
                sourceBundleID: optText(12),
                sourceAppName: optText(13),
                customTitle: optText(14),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 15)),
                textTruncated: truncated)
            if container == "history" {
                history.append(item)
            } else if let board = boardsByID[container] {
                boardsByID[container]?.items.append(item)
            }
        }
        sqlite3_finalize(stmt)
        let pinboards = boardOrder.compactMap { boardsByID[$0] }
        return Snapshot(history: history, pinboards: pinboards)
    }

    // MARK: - Write

    /// Rewrites the given containers' rows and upserts pinboard metadata in one
    /// transaction. Containers not named here keep their rows untouched.
    /// `history` uses the container key "history"; a pinboard's key is its UUID.
    func flush(history: [ClipItem], pinboards: [Pinboard],
               dirtyContainers: Set<String>, deletedBlobIDs: [UUID]) -> Bool {
        // Rehydrate full payloads for preview-truncated items BEFORE the
        // transaction deletes their rows — a SELECT after the DELETE inside
        // the same transaction would find nothing and persist the preview.
        var rehydrated: [UUID: (text: String?, rtfData: Data?)] = [:]
        var needsFetch = history.filter(\.textTruncated)
        for key in dirtyContainers where key != "history" {
            if let board = pinboards.first(where: { $0.id.uuidString == key }) {
                needsFetch += board.items.filter(\.textTruncated)
            }
        }
        for item in needsFetch where rehydrated[item.id] == nil {
            rehydrated[item.id] = loadFullPayload(id: item.id)
        }

        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return false }
        var ok = true

        for key in dirtyContainers {
            let esc = key.replacingOccurrences(of: "'", with: "''")
            ok = ok && exec("DELETE FROM clips WHERE container='\(esc)';")
            if key == "history" {
                ok = ok && insertRows(history, container: "history", rehydrated: rehydrated)
            } else if let board = pinboards.first(where: { $0.id.uuidString == key }) {
                ok = ok && insertRows(board.items, container: key, rehydrated: rehydrated)
            } else {
                ok = ok && exec("DELETE FROM pinboards WHERE id='\(esc)';")
            }
        }

        for board in pinboards {
            let id = board.id.uuidString
            let name = board.name.replacingOccurrences(of: "'", with: "''")
            let color = board.colorHex.replacingOccurrences(of: "'", with: "''")
            ok = ok && exec("INSERT OR REPLACE INTO pinboards(id, name, color_hex) VALUES('\(id)','\(name)','\(color)');")
        }

        for id in deletedBlobIDs {
            for ext in ["txt", "rtf"] {
                try? FileManager.default.removeItem(
                    at: blobsDir.appendingPathComponent("\(id.uuidString).\(ext)"))
            }
        }

        if ok {
            ok = exec("COMMIT;")
        } else {
            _ = exec("ROLLBACK;")
        }
        return ok
    }

    private func insertRows(_ items: [ClipItem], container: String,
                            rehydrated: [UUID: (text: String?, rtfData: Data?)]) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            INSERT OR REPLACE INTO clips(id, container, position, type, text_truncated, text_value,
                                         text_path, rtf_blob, rtf_path, image_file, image_hash,
                                         file_urls, color_hex, source_bundle, source_name, title,
                                         created_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        for (index, item) in items.enumerated() {
            // Memory may hold only a preview (trimMemoryPreviews); the database
            // must always receive the FULL payload — re-read it for truncated
            // items instead of persisting the preview over the real content.
            var srcText = item.text
            var srcRTF = item.rtfData
            if item.textTruncated, let full = rehydrated[item.id] {
                srcText = full.text ?? srcText
                srcRTF = full.rtfData ?? srcRTF
            }
            var textValue: String? = srcText
            var textPath: String?
            if let text = srcText, text.utf8.count > Self.inlineLimit {
                textValue = nil
                textPath = try? Self.writeBlob(Data(text.utf8), id: item.id, ext: "txt", dir: blobsDir)
            }
            var rtfBlob: Data? = srcRTF
            var rtfPath: String?
            if let rtf = srcRTF, rtf.count > Self.inlineLimit {
                rtfBlob = nil
                rtfPath = try? Self.writeBlob(rtf, id: item.id, ext: "rtf", dir: blobsDir)
            }

            // 1 id, 2 container, 3 position, 4 type, 5 text_truncated,
            // 6 text_value, 7 text_path, 8 rtf_blob, 9 rtf_path, 10 image_file,
            // 11 image_hash, 12 file_urls, 13 color_hex, 14 source_bundle,
            // 15 source_name, 16 title, 17 created_at
            sqlite3_bind_text(stmt, 1, item.id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, container, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, Int32(index))
            sqlite3_bind_text(stmt, 4, item.type.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 5, item.textTruncated ? 1 : 0)
            if let v = textValue { sqlite3_bind_text(stmt, 6, v, -1, SQLITE_TRANSIENT) }
            else { sqlite3_bind_null(stmt, 6) }
            if let v = textPath { sqlite3_bind_text(stmt, 7, v, -1, SQLITE_TRANSIENT) }
            else { sqlite3_bind_null(stmt, 7) }
            if let v = rtfBlob { v.withUnsafeBytes { sqlite3_bind_blob(stmt, 8, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) } }
            else { sqlite3_bind_null(stmt, 8) }
            if let v = rtfPath { sqlite3_bind_text(stmt, 9, v, -1, SQLITE_TRANSIENT) }
            else { sqlite3_bind_null(stmt, 9) }
            if let v = item.imageFileName { sqlite3_bind_text(stmt, 10, v, -1, SQLITE_TRANSIENT) }
            else { sqlite3_bind_null(stmt, 10) }
            if let v = item.imageHash { sqlite3_bind_text(stmt, 11, v, -1, SQLITE_TRANSIENT) }
            else { sqlite3_bind_null(stmt, 11) }
            let urls = item.fileURLs.joined(separator: "\u{1f}")
            if !urls.isEmpty { sqlite3_bind_text(stmt, 12, urls, -1, SQLITE_TRANSIENT) }
            else { sqlite3_bind_null(stmt, 12) }
            if let v = item.colorHex { sqlite3_bind_text(stmt, 13, v, -1, SQLITE_TRANSIENT) }
            else { sqlite3_bind_null(stmt, 13) }
            if let v = item.sourceBundleID { sqlite3_bind_text(stmt, 14, v, -1, SQLITE_TRANSIENT) }
            else { sqlite3_bind_null(stmt, 14) }
            if let v = item.sourceAppName { sqlite3_bind_text(stmt, 15, v, -1, SQLITE_TRANSIENT) }
            else { sqlite3_bind_null(stmt, 15) }
            if let v = item.customTitle { sqlite3_bind_text(stmt, 16, v, -1, SQLITE_TRANSIENT) }
            else { sqlite3_bind_null(stmt, 16) }
            sqlite3_bind_double(stmt, 17, item.createdAt.timeIntervalSince1970)

            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
            sqlite3_reset(stmt)
        }
        return true
    }

    /// Loads the full text/RTF payload of a single clip (used by paste/edit
    /// when the in-memory item only carries a preview).
    func loadFullPayload(id: UUID) -> (text: String?, rtfData: Data?) {
        var stmt: OpaquePointer?
        let sql = "SELECT text_value, text_path, rtf_blob, rtf_path FROM clips WHERE id=?1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (nil, nil) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (nil, nil) }
        func optText(_ i: Int32) -> String? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, i))
        }
        func optBlob(_ i: Int32) -> Data? {
            guard sqlite3_column_type(stmt, i) != SQLITE_NULL,
                  let bytes = sqlite3_column_blob(stmt, i) else { return nil }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, i)))
        }
        func readBlobFile(_ i: Int32) -> Data? {
            optText(i).flatMap { try? Data(contentsOf: blobsDir.appendingPathComponent($0)) }
        }
        let text = optText(0) ?? readBlobFile(1).flatMap { String(data: $0, encoding: .utf8) }
        let rtf = optBlob(2) ?? readBlobFile(3)
        return (text, rtf)
    }

    /// Online consistent snapshot via VACUUM INTO (no lock on live reads).
    func backup(to url: URL) -> Bool {
        let escaped = url.path.replacingOccurrences(of: "'", with: "''")
        return exec("VACUUM INTO '\(escaped)';")
    }

    private static func writeBlob(_ data: Data, id: UUID, ext: String, dir: URL) throws -> String {
        let name = "\(id.uuidString).\(ext)"
        try data.write(to: dir.appendingPathComponent(name), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: dir.appendingPathComponent(name).path)
        return name
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
