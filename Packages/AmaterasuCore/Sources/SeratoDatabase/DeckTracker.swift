import Domain
import Foundation

/// Turns Serato history rows into deck states (rules in docs/serato-findings.md §5).
///
/// - Decks are shown only while the newest session is open (`end_time = -1`).
/// - Each deck's newest entry is its current track while that entry has `end_time = -1`; ejecting or
///   replacing sets `end_time`. Taking the newest entry skips orphan rows.
/// - `played` 0 → 1 marks the start of playback. Serato stores no time for it, so the tracker remembers
///   when it first saw each entry played: the moment of the change if it saw the entry unplayed first,
///   otherwise the load time (the track was already playing, e.g. Amaterasu started mid-set).
/// - A track that already played earlier in the session (and finished before this load, so not an
///   instant double) gets `playedEarlierAt`.
/// - BPM and Key come from the library's current analysis (`library_bpm` / `library_key_value`) when there
///   is one, else from the history entry, which only holds what was known when the track was loaded.
public struct DeckTracker: Sendable {
    private var seenUnplayed: Set<Int64> = []
    private var playStarts: [Int64: Date] = [:]

    public init() {}

    /// - Parameters:
    ///   - session: the newest history session, if any.
    ///   - entries: the entries of that session (any order).
    ///   - now: when these rows were read.
    public mutating func update(session: HistorySession?, entries: [SQLRow], now: Date) -> [DeckState] {
        guard let session, session.isOpen else {
            seenUnplayed.removeAll()
            playStarts.removeAll()
            return []
        }

        // The newest entry per deck.
        var newest: [Int: SQLRow] = [:]
        for row in entries {
            guard let deckID = row["deck"].string.flatMap({ Int($0) }), (1...4).contains(deckID),
                  let id = row["id"].int64
            else { continue }
            if let current = newest[deckID], (current["id"].int64 ?? 0) > id { continue }
            newest[deckID] = row
        }

        var decks: [DeckState] = []
        var onDecks: Set<Int64> = []
        for (deckID, row) in newest {
            guard let entryID = row["id"].int64, row["end_time"].int64 == -1 else { continue }
            onDecks.insert(entryID)

            let played = row["played"].int64 == 1
            let loadedAt = row["start_time"].int64.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            var playStartedAt: Date?
            if played {
                let started = playStarts[entryID] ?? (seenUnplayed.contains(entryID) ? now : loadedAt ?? now)
                playStarts[entryID] = started
                playStartedAt = started
            } else {
                seenUnplayed.insert(entryID)
            }

            decks.append(DeckState(
                id: deckID,
                title: SessionHistory.text(row["name"]),
                artist: SessionHistory.text(row["artist"]),
                bpm: SessionHistory.positive(row["library_bpm"]) ?? SessionHistory.positive(row["bpm"]),
                key: SessionHistory.key(of: row),
                hasStartedPlaying: played,
                loadedAt: loadedAt,
                playStartedAt: playStartedAt,
                playedEarlierAt: Self.earlierPlay(of: row, in: entries)
            ))
        }

        // Forget entries that are no longer on a deck.
        seenUnplayed.formIntersection(onDecks)
        playStarts = playStarts.filter { onDecks.contains($0.key) }

        return decks.sorted { $0.id < $1.id }
    }

    /// The latest start of an earlier play of the same track that had finished before `row` was loaded.
    /// Previews (shorter than `SessionHistory.minimumPlaySeconds`) do not count.
    private static func earlierPlay(of row: SQLRow, in entries: [SQLRow]) -> Date? {
        guard let id = row["id"].int64, let loaded = row["start_time"].int64 else { return nil }
        let identity = SessionHistory.identity(of: row)
        let starts = entries.compactMap { other -> Int64? in
            guard let otherID = other["id"].int64, otherID < id,
                  other["played"].int64 == 1,
                  let end = other["end_time"].int64, end >= 0, end <= loaded,
                  let start = other["start_time"].int64, end - start >= SessionHistory.minimumPlaySeconds,
                  SessionHistory.identity(of: other) == identity
            else { return nil }
            return start
        }
        return starts.max().map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}
