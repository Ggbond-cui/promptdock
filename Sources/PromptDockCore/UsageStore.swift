import Foundation
import SQLite3

public enum UsageKind: String, Sendable, Equatable {
    case paste, copy, action
}

public struct UsageEvent: Sendable, Equatable {
    public var promptID: String
    public var usedAt: Date
    public var kind: UsageKind

    public init(promptID: String, usedAt: Date, kind: UsageKind) {
        self.promptID = promptID
        self.usedAt = usedAt
        self.kind = kind
    }
}

public enum UsageStoreError: Error, Equatable {
    case open(path: String, message: String)
    case sqlite(message: String)
}

/// 使用事件存储（SQLite）。表结构见 docs/spec.md 第 6.3 节。
/// 时间以 Unix 秒存储，亚秒部分舍去。非线程安全，由调用方保证在同一线程使用。
public final class UsageStore {
    public static let defaultRetentionDays = 180
    private static let schemaVersion: Int32 = 1
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var db: OpaquePointer?

    /// - Parameter path: 数据库文件路径；传 ":memory:" 使用内存库。父目录不存在时自动创建。
    public init(path: String) throws {
        if path != ":memory:" {
            let dir = (path as NSString).deletingLastPathComponent
            do {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            } catch {
                throw UsageStoreError.open(path: path, message: error.localizedDescription)
            }
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw UsageStoreError.open(path: path, message: message)
        }
        db = handle
        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    public func record(promptID: String, kind: UsageKind, at date: Date = Date()) throws {
        try withStatement("INSERT INTO usage_event (prompt_id, used_at, kind) VALUES (?, ?, ?)") { stmt in
            sqlite3_bind_text(stmt, 1, promptID, -1, Self.transient)
            sqlite3_bind_int64(stmt, 2, Self.seconds(date))
            sqlite3_bind_text(stmt, 3, kind.rawValue, -1, Self.transient)
            try step(stmt, expecting: SQLITE_DONE)
        }
    }

    /// 返回指定时间（含）之后的事件，按时间升序。
    public func events(since date: Date) throws -> [UsageEvent] {
        try withStatement(
            "SELECT prompt_id, used_at, kind FROM usage_event WHERE used_at >= ? ORDER BY used_at, id"
        ) { stmt in
            sqlite3_bind_int64(stmt, 1, Self.seconds(date))
            var result: [UsageEvent] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw lastError() }
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let at = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 1)))
                let rawKind = String(cString: sqlite3_column_text(stmt, 2))
                // 未知 kind（来自未来版本）跳过，不影响其余数据
                guard let kind = UsageKind(rawValue: rawKind) else { continue }
                result.append(UsageEvent(promptID: id, usedAt: at, kind: kind))
            }
            return result
        }
    }

    /// 删除保留期之前的事件，返回删除条数。
    @discardableResult
    public func purgeExpired(now: Date = Date(), retentionDays: Int = UsageStore.defaultRetentionDays) throws -> Int {
        let cutoff = now.addingTimeInterval(-TimeInterval(retentionDays) * 86_400)
        return try withStatement("DELETE FROM usage_event WHERE used_at < ?") { stmt in
            sqlite3_bind_int64(stmt, 1, Self.seconds(cutoff))
            try step(stmt, expecting: SQLITE_DONE)
            return Int(sqlite3_changes(db))
        }
    }

    // MARK: - 内部

    private func migrate() throws {
        let current = try withStatement("PRAGMA user_version") { stmt -> Int32 in
            try step(stmt, expecting: SQLITE_ROW)
            return sqlite3_column_int(stmt, 0)
        }
        guard current < Self.schemaVersion else { return }
        try exec("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS usage_event (
              id        INTEGER PRIMARY KEY AUTOINCREMENT,
              prompt_id TEXT    NOT NULL,
              used_at   INTEGER NOT NULL,
              kind      TEXT    NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_usage_prompt ON usage_event(prompt_id, used_at);
            PRAGMA user_version = \(Self.schemaVersion);
            """)
    }

    private func exec(_ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errmsg) == SQLITE_OK else {
            let message = errmsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errmsg)
            throw UsageStoreError.sqlite(message: message)
        }
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw lastError()
        }
        defer { sqlite3_finalize(stmt) }
        return try body(stmt)
    }

    private func step(_ stmt: OpaquePointer, expecting code: Int32) throws {
        guard sqlite3_step(stmt) == code else { throw lastError() }
    }

    private func lastError() -> UsageStoreError {
        .sqlite(message: String(cString: sqlite3_errmsg(db)))
    }

    private static func seconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.down))
    }
}
