import Domain
import Foundation

/// Reads a session's history entries: what played, and which tracks were loaded.
public enum SessionHistory {
    /// Plays shorter than this (on the deck, in seconds) are previews, not part of the set.
    public static let minimumPlaySeconds: Int64 = 30

    /// The tracks that played, in order.
    ///
    /// Entries that never played (loads without playing, orphan rows) are left out, and so are previews:
    /// tracks on a deck for less than `minimumPlaySeconds`. A track loaded onto another deck while it is
    /// still playing (instant doubles) overlaps the previous play and counts once.
    public static func playedTracks(from entries: [SQLRow]) -> [PlayedTrack] {
        let played = entries
            .filter { $0["played"].int64 == 1 }
            .sorted { ($0["start_time"].int64 ?? 0, $0["id"].int64 ?? 0) < ($1["start_time"].int64 ?? 0, $1["id"].int64 ?? 0) }

        var tracks: [PlayedTrack] = []
        var lastIdentity: String?
        var lastEnd: Int64? // -1 while still on a deck
        for row in played {
            let identity = Self.identity(of: row)
            let start = row["start_time"].int64 ?? 0
            let end = row["end_time"].int64 ?? -1
            if identity == lastIdentity, let previousEnd = lastEnd, previousEnd == -1 || start <= previousEnd,
               let previous = tracks.popLast() {
                // An instant double: one play that continues on the other deck.
                lastEnd = (previousEnd == -1 || end == -1) ? -1 : max(previousEnd, end)
                tracks.append(previous.ending(at: lastEnd))
                continue
            }
            tracks.append(PlayedTrack(
                title: text(row["name"]),
                artist: text(row["artist"]),
                deck: row["deck"].string.flatMap { Int($0) } ?? 0,
                startedAt: Date(timeIntervalSince1970: TimeInterval(start)),
                endedAt: end >= 0 ? Date(timeIntervalSince1970: TimeInterval(end)) : nil,
                bpm: positive(row["library_bpm"]) ?? positive(row["bpm"]),
                key: key(of: row),
                length: positive(row["length_sec"])
            ))
            lastIdentity = identity
            lastEnd = end
        }
        return tracks.filter { track in
            guard let end = track.endedAt else { return true } // still playing
            return end.timeIntervalSince(track.startedAt) >= TimeInterval(minimumPlaySeconds)
        }
    }

    static func positive(_ value: SQLValue) -> Double? {
        value.double.flatMap { $0 > 0 ? $0 : nil }
    }

    /// The library's current Key first, then what was recorded at load, then the key string.
    static func key(of row: SQLRow) -> MusicalKey? {
        for column in ["library_key_value", "key_value"] {
            if let value = row[column].int64, let key = MusicalKey(seratoKeyValue: Int(value)) { return key }
        }
        return row["key"].string.flatMap(KeyParser.parse)
    }

    public static func summary(of session: HistorySession, entries: [SQLRow]) -> SessionSummary {
        SessionSummary(
            id: session.id,
            name: session.name,
            startTime: session.startTime,
            isOpen: session.isOpen,
            tracks: playedTracks(from: entries),
            assetIDs: Set(entries.compactMap { row in row["asset_id"].int64.flatMap { $0 > 0 ? $0 : nil } })
        )
    }

    /// The same track across entries: the library asset if known, else its file, else its name.
    static func identity(of row: SQLRow) -> String {
        if let asset = row["asset_id"].int64, asset > 0 { return "asset:\(asset)" }
        if let path = row["portable_id"].string, !path.isEmpty { return "path:\(path)" }
        return "name:\(row["name"].string ?? "")|\(row["artist"].string ?? "")"
    }

    static func text(_ value: SQLValue) -> String? {
        guard let text = value.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

private extension PlayedTrack {
    func ending(at end: Int64?) -> PlayedTrack {
        PlayedTrack(
            title: title, artist: artist, deck: deck, startedAt: startedAt,
            endedAt: end.flatMap { $0 >= 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
            bpm: bpm, key: key, length: length
        )
    }
}
