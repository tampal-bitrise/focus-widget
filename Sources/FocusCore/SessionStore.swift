import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One focused work session. `endedAt == nil` means it is still running.
public struct Session: Equatable {
    public let id: Int64
    public var tag: String
    public let startedAt: Date
    public let endedAt: Date?

    public var isRunning: Bool { endedAt == nil }
    public func duration(now: Date = Date()) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }
}

public struct TagTotal: Equatable {
    public let tag: String
    public let seconds: Int

    public init(tag: String, seconds: Int) {
        self.tag = tag
        self.seconds = seconds
    }
}

public enum StoreError: Error, LocalizedError {
    case sqlite(String)
    public var errorDescription: String? {
        switch self { case .sqlite(let message): return "SQLite: \(message)" }
    }
}

/// SQLite-backed store. Single file, no sidecars, so it can be copied or queried with the `sqlite3` CLI.
public final class SessionStore {
    public let url: URL
    private var db: OpaquePointer?

    /// `$FOCUS_WIDGET_DB` if set, otherwise ~/Library/Application Support/FocusWidget/focus.sqlite
    public static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["FOCUS_WIDGET_DB"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("FocusWidget/focus.sqlite")
    }

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_close(handle)
            throw StoreError.sqlite(message)
        }
        db = handle
        try exec("""
        CREATE TABLE IF NOT EXISTS sessions (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            tag        TEXT    NOT NULL,
            started_at INTEGER NOT NULL,   -- unix epoch seconds
            ended_at   INTEGER             -- NULL while running
        );
        CREATE INDEX IF NOT EXISTS idx_sessions_started_at ON sessions(started_at);
        """)
    }

    deinit { sqlite3_close(db) }

    // MARK: - Commands

    /// Starts a session. Any session still open is closed first.
    @discardableResult
    public func start(tag: String, at date: Date = Date()) throws -> Session {
        if current() != nil { try stop(at: date) }
        let stmt = try prepare("INSERT INTO sessions (tag, started_at) VALUES (?, ?)")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, tag)
        sqlite3_bind_int64(stmt, 2, Int64(date.timeIntervalSince1970))
        try step(stmt)
        return Session(id: sqlite3_last_insert_rowid(db), tag: tag, startedAt: date, endedAt: nil)
    }

    /// Ends the running session. Sessions shorter than `minimumSeconds` are discarded (returns nil).
    @discardableResult
    public func stop(at date: Date = Date(), minimumSeconds: Int = 0) throws -> Session? {
        guard let running = current() else { return nil }
        let endedAt = max(date, running.startedAt)
        if Int(endedAt.timeIntervalSince(running.startedAt)) < minimumSeconds {
            try delete(id: running.id)
            return nil
        }
        let stmt = try prepare("UPDATE sessions SET ended_at = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(endedAt.timeIntervalSince1970))
        sqlite3_bind_int64(stmt, 2, running.id)
        try step(stmt)
        return Session(id: running.id, tag: running.tag, startedAt: running.startedAt, endedAt: endedAt)
    }

    public func retag(id: Int64, tag: String) throws {
        let stmt = try prepare("UPDATE sessions SET tag = ? WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, tag)
        sqlite3_bind_int64(stmt, 2, id)
        try step(stmt)
    }

    public func delete(id: Int64) throws {
        let stmt = try prepare("DELETE FROM sessions WHERE id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        try step(stmt)
    }

    // MARK: - Queries

    /// The open session, if any.
    public func current() -> Session? {
        guard let stmt = try? prepare(
            "SELECT id, tag, started_at, ended_at FROM sessions WHERE ended_at IS NULL ORDER BY started_at DESC LIMIT 1"
        ) else { return nil }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? readSession(stmt) : nil
    }

    /// Distinct tags, most recently used first.
    public func recentTags(limit: Int = 12) -> [String] {
        guard let stmt = try? prepare(
            "SELECT tag FROM sessions GROUP BY tag ORDER BY MAX(started_at) DESC LIMIT ?"
        ) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var tags: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { tags.append(column(stmt, 0)) }
        return tags
    }

    /// Seconds per tag for sessions started at or after `since`, largest first. A running session counts up to `now`.
    public func totals(since: Date, now: Date = Date()) -> [TagTotal] {
        guard let stmt = try? prepare("""
            SELECT tag, SUM(COALESCE(ended_at, ?) - started_at) AS secs
            FROM sessions WHERE started_at >= ?
            GROUP BY tag ORDER BY secs DESC, tag ASC
            """) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(now.timeIntervalSince1970))
        sqlite3_bind_int64(stmt, 2, Int64(since.timeIntervalSince1970))
        var totals: [TagTotal] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            totals.append(TagTotal(tag: column(stmt, 0), seconds: Int(sqlite3_column_int64(stmt, 1))))
        }
        return totals
    }

    /// Sessions started at or after `since`, newest first.
    public func sessions(since: Date) -> [Session] {
        guard let stmt = try? prepare(
            "SELECT id, tag, started_at, ended_at FROM sessions WHERE started_at >= ? ORDER BY started_at DESC"
        ) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(since.timeIntervalSince1970))
        var rows: [Session] = []
        while sqlite3_step(stmt) == SQLITE_ROW { rows.append(readSession(stmt)) }
        return rows
    }

    // MARK: - SQLite plumbing

    private func readSession(_ stmt: OpaquePointer) -> Session {
        let ended: Date? = sqlite3_column_type(stmt, 3) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 3)))
        return Session(
            id: sqlite3_column_int64(stmt, 0),
            tag: column(stmt, 1),
            startedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 2))),
            endedAt: ended
        )
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw lastError() }
        return stmt
    }

    private func step(_ stmt: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw lastError() }
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(err)
            throw StoreError.sqlite(message)
        }
    }

    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ text: String) {
        sqlite3_bind_text(stmt, index, text, -1, SQLITE_TRANSIENT)
    }

    private func column(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: text)
    }

    private func lastError() -> StoreError {
        .sqlite(String(cString: sqlite3_errmsg(db)))
    }
}
