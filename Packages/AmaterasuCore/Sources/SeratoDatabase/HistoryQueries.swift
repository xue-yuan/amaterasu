import Foundation

public struct HistorySession: Equatable, Sendable {
    public let id: Int64
    public let startTime: Date
    /// nil while the session is still open (Serato stores `end_time = -1` until it ends the session).
    public let endTime: Date?
    public let name: String

    public var isOpen: Bool { endTime == nil }

    init(row: SQLRow) {
        id = row["id"].int64 ?? -1
        startTime = Date(timeIntervalSince1970: TimeInterval(row["start_time"].int64 ?? 0))
        endTime = row["end_time"].int64.flatMap { $0 < 0 ? nil : Date(timeIntervalSince1970: TimeInterval($0)) }
        name = row["name"].string ?? ""
    }
}

public enum HistoryQueries {
    /// Most recent sessions first.
    public static func sessions(_ database: SQLiteDatabase, limit: Int) throws -> [HistorySession] {
        try database.query(
            "SELECT id, start_time, end_time, name FROM history_session ORDER BY id DESC LIMIT ?",
            [.integer(Int64(limit))]
        ).map(HistorySession.init(row:))
    }

    public static func session(_ database: SQLiteDatabase, id: Int64) throws -> HistorySession? {
        try database.query(
            "SELECT id, start_time, end_time, name FROM history_session WHERE id = ?",
            [.integer(id)]
        ).first.map(HistorySession.init(row:))
    }

    public static func entryCount(_ database: SQLiteDatabase, sessionID: Int64) throws -> Int {
        let rows = try database.query("SELECT count(*) FROM history_entry WHERE session_id = ?", [.integer(sessionID)])
        return Int(rows.first?.values.first?.int64 ?? 0)
    }

    /// Every column of every entry in a session, ordered by id. Generic rows on purpose:
    /// Phase 0 diffs all columns to learn what Serato changes and when.
    public static func entryRows(_ database: SQLiteDatabase, sessionID: Int64) throws -> [SQLRow] {
        try database.query("SELECT * FROM history_entry WHERE session_id = ? ORDER BY id", [.integer(sessionID)])
    }

    /// Every entry of a session, ordered by id, plus the track's current library analysis as
    /// `library_bpm` / `library_key_value` (NULL when the entry has no library asset).
    ///
    /// Serato writes BPM and Key into the history entry when the track is loaded and never updates it, so a
    /// track loaded before analysis finished, or whose BPM was changed later, is only right in `asset`.
    public static func entryRowsWithLibraryValues(_ database: SQLiteDatabase, sessionID: Int64) throws -> [SQLRow] {
        try database.query(
            """
            SELECT h.*, a.bpm AS library_bpm, a.key_value AS library_key_value
            FROM history_entry h LEFT JOIN asset a ON a.id = h.asset_id
            WHERE h.session_id = ?
            ORDER BY h.id
            """,
            [.integer(sessionID)]
        )
    }

    /// The newest entry on each deck in a session, ordered by deck. Taking the newest row per deck skips
    /// the orphan rows Serato sometimes leaves behind with `end_time = -1` (Phase 0 findings §2.4).
    public static func latestEntryPerDeck(_ database: SQLiteDatabase, sessionID: Int64) throws -> [SQLRow] {
        try database.query(
            """
            SELECT * FROM history_entry
            WHERE id IN (SELECT max(id) FROM history_entry WHERE session_id = ? GROUP BY deck)
            ORDER BY deck
            """,
            [.integer(sessionID)]
        )
    }

    /// `location.id` → `location.path`. In 4.0.1 every path observed so far is NULL (locations are identified
    /// by a volume UUID); NULL / empty is assumed to be the boot volume (Phase 0 hypothesis).
    public static func locationPaths(_ database: SQLiteDatabase) throws -> [Int64: String] {
        var paths: [Int64: String] = [:]
        for row in try database.query("SELECT id, path FROM location") {
            if let id = row["id"].int64 { paths[id] = row["path"].string ?? "" }
        }
        return paths
    }

    /// Full file path of an entry: `location.path` + "/" + `portable_id` (Phase 0 hypothesis, verified for the
    /// boot volume only). Streaming tracks (`portable_id` like `streaming://spotify/…`) have no file: nil.
    public static func filePath(of entry: SQLRow, locations: [Int64: String]) -> String? {
        guard let portable = entry["portable_id"].string, !portable.isEmpty, !portable.contains("://") else { return nil }
        let base = entry["location_id"].int64.flatMap { locations[$0] } ?? ""
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        return trimmedBase + "/" + portable
    }
}
