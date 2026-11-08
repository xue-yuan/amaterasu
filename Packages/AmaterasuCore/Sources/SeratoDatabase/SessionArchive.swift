import Domain
import Foundation

/// Reads past and current Serato sessions, for the session analysis window.
///
/// While Serato has its database open, every call uses a short-lived read-only connection. Otherwise it
/// works on a private copy, kept (and re-copied when the database file changes) until `close()`.
public actor SessionArchive {
    public struct Session: Identifiable, Equatable, Sendable {
        public let id: Int64
        public let name: String
        public let startTime: Date
        public let isOpen: Bool
        public let trackCount: Int
    }

    private let database: URL
    private var copy: SQLiteDatabase?
    private var copiedModification: Date?

    public init(database: URL = SeratoLibrary.databaseURL) {
        self.database = database
    }

    /// Newest first. Sessions in which nothing played are left out.
    public func sessions(limit: Int = 300) throws -> [Session] {
        try read { connection in
            let sessions = try HistoryQueries.sessions(connection, limit: limit)
            guard let oldest = sessions.last?.id else { return [] }
            let rows = try connection.query(
                """
                SELECT id, session_id, deck, played, start_time, end_time, name, artist, asset_id, portable_id
                FROM history_entry WHERE session_id >= ? AND played = 1
                """,
                [.integer(oldest)]
            )
            let bySession = Dictionary(grouping: rows) { $0["session_id"].int64 ?? -1 }
            return sessions.compactMap { session in
                let count = SessionHistory.playedTracks(from: bySession[session.id] ?? []).count
                guard count > 0 else { return nil }
                return Session(id: session.id, name: session.name, startTime: session.startTime, isOpen: session.isOpen, trackCount: count)
            }
        }
    }

    /// The tracks that played in a session, with Serato's current BPM / Key analysis.
    public func tracks(sessionID: Int64) throws -> [PlayedTrack] {
        try read { connection in
            SessionHistory.playedTracks(from: try HistoryQueries.entryRowsWithLibraryValues(connection, sessionID: sessionID))
        }
    }

    /// Drops the private copy, if any.
    public func close() {
        copy = nil
        copiedModification = nil
    }

    private func read<T>(_ body: (SQLiteDatabase) throws -> T) throws -> T {
        if FileManager.default.fileExists(atPath: SeratoLibrary.walURL(for: database).path),
           let live = try? SeratoLibrary.openLive(database) {
            copy = nil // closed when this function returns
            return try live.readTransaction { try body(live) }
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: database.path))?[.modificationDate] as? Date
        if copy == nil || modified != copiedModification {
            copy = try SeratoLibrary.openSnapshot(of: database)
            copiedModification = modified
        }
        guard let copy else { throw SeratoLibraryError.databaseNotFound(database) }
        return try body(copy)
    }
}
