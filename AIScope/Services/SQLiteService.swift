import Foundation
import SQLite3

/// Read-only access to SQLite databases (used to extract Cursor's session token).
enum SQLiteService {

    enum SQLiteError: Error {
        case openFailed(String)
        case prepareFailed(String)
        case notFound
        case copyFailed(String)
    }

    // MARK: - Public API

    /// Reads a single string value from `ItemTable` by key.
    /// This is the VS Code / Cursor storage format used in `state.vscdb`.
    static func readItemTableValue(dbPath: String, key: String) throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiscope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 把主文件连同 WAL/SHM 伴生文件一并拷贝（WAL 模式 db 缺 -wal 会打不开）
        let tempDB = tempDir.appendingPathComponent("state.vscdb")
        try copyIfExists(dbPath,                                   to: tempDB.path)
        try copyIfExists(dbPath + "-wal",                          to: tempDB.path + "-wal")
        try copyIfExists(dbPath + "-shm",                          to: tempDB.path + "-shm")

        // 必须用 READWRITE：下一条 PRAGMA 会改 journal_mode，需要写权限
        let db = try openReadWrite(path: tempDB.path)
        defer { sqlite3_close(db) }

        // 把副本切回 DELETE 模式：触发 WAL checkpoint，将未合并的写操作写回主 db，
        // 后续查询不再依赖 -wal/-shm 文件（原 db 的 journal_mode 持久化在文件头，
        // 单纯拷贝打开会因找不到伴生文件而报 "unable to open database file"）。
        var pragmaStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA journal_mode=DELETE", -1, &pragmaStmt, nil) == SQLITE_OK {
            sqlite3_step(pragmaStmt)
            sqlite3_finalize(pragmaStmt)
        }

        let query = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(errorMessage(db))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw SQLiteError.notFound
        }

        guard let cStr = sqlite3_column_text(stmt, 0) else {
            throw SQLiteError.notFound
        }
        return String(cString: cStr)
    }

    /// 静默拷贝：源不存在时跳过（伴生文件可能不在），其他 IO 错误向上抛。
    private static func copyIfExists(_ src: String, to dst: String) throws {
        guard FileManager.default.fileExists(atPath: src) else { return }
        try FileManager.default.copyItem(atPath: src, toPath: dst)
    }

    // MARK: - Private helpers

    private static func openReadWrite(path: String) throws -> OpaquePointer? {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        defer {
            if result != SQLITE_OK, let handle { sqlite3_close(handle) }
        }
        guard result == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw SQLiteError.openFailed(msg)
        }
        return handle
    }

    private static func errorMessage(_ db: OpaquePointer?) -> String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
    }
}
