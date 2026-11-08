import Domain
import Foundation

public enum LibraryQueries {
    /// Analysed local tracks (not streaming, not missing or corrupt) in `keys`, optionally only those whose
    /// BPM, as is, doubled or halved, falls within `bpmRange`.
    public static func candidates(_ database: SQLiteDatabase, keys: [MusicalKey], bpmRange: ClosedRange<Double>?) throws -> [LibraryTrack] {
        guard !keys.isEmpty else { return [] }
        var sql = """
            SELECT id, name, artist, bpm, key_value, dj_play_count FROM asset
            WHERE key_value IN (\(Array(repeating: "?", count: keys.count).joined(separator: ", ")))
              AND is_missing = 0 AND is_corrupt = 0 AND portable_id NOT LIKE '%://%'
            """
        var parameters: [SQLValue] = keys.map { .integer(Int64($0.seratoKeyValue)) }
        if let range = bpmRange {
            // other × r within the range ⇔ other within range / r, for r = 1, 2, ½.
            sql += " AND (bpm BETWEEN ? AND ? OR bpm BETWEEN ? AND ? OR bpm BETWEEN ? AND ?)"
            parameters += [
                .real(range.lowerBound), .real(range.upperBound),
                .real(range.lowerBound / 2), .real(range.upperBound / 2),
                .real(range.lowerBound * 2), .real(range.upperBound * 2),
            ]
        }
        return try database.query(sql, parameters).compactMap { row in
            guard let id = row["id"].int64 else { return nil }
            return LibraryTrack(
                id: id,
                title: SessionHistory.text(row["name"]),
                artist: SessionHistory.text(row["artist"]),
                bpm: row["bpm"].double.flatMap { $0 > 0 ? $0 : nil },
                key: row["key_value"].int64.flatMap { MusicalKey(seratoKeyValue: Int($0)) },
                playCount: Int(row["dj_play_count"].int64 ?? 0)
            )
        }
    }
}

/// "Next track" suggestions from the Serato library.
public enum LibrarySuggestions {
    /// Opens the live database read-only (Serato must be running), fetches candidates and ranks them with
    /// `TrackSuggester`. Does blocking I/O: call it off the main thread.
    public static func fetch(
        database: URL = SeratoLibrary.databaseURL,
        mainKey: MusicalKey,
        mainBPM: Double?,
        thresholds: BPMThresholds,
        includeAdvanced: Bool,
        excluding excluded: Set<Int64>,
        limit: Int = 3
    ) throws -> [TrackSuggestion] {
        let keys = HarmonicRecommender.recommendations(for: mainKey, includeAdvanced: includeAdvanced).map(\.key)
        // The BPMs that need at most the green pitch change: base / (1 ± t).
        let range = mainBPM.map { bpm in
            let t = thresholds.compatible / 100
            return (bpm / (1 + t))...(bpm / max(1 - t, 0.01))
        }
        let connection = try SeratoLibrary.openLive(database) // closed when this function returns
        let candidates = try LibraryQueries.candidates(connection, keys: keys, bpmRange: range)
        return TrackSuggester.suggest(
            from: candidates, mainKey: mainKey, mainBPM: mainBPM, thresholds: thresholds,
            includeAdvanced: includeAdvanced, excluding: excluded, limit: limit
        )
    }
}
