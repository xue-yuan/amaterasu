import Foundation

/// A track in the DJ's library (a Serato asset).
public struct LibraryTrack: Identifiable, Equatable, Sendable {
    /// Serato's asset id.
    public let id: Int64
    public let title: String?
    public let artist: String?
    public let bpm: Double?
    public let key: MusicalKey?
    /// How often Serato has played it.
    public let playCount: Int

    public init(id: Int64, title: String?, artist: String?, bpm: Double?, key: MusicalKey?, playCount: Int = 0) {
        self.id = id
        self.title = title
        self.artist = artist
        self.bpm = bpm
        self.key = key
        self.playCount = playCount
    }
}

public struct TrackSuggestion: Identifiable, Equatable, Sendable {
    public let track: LibraryTrack
    public let relation: KeyRelation
    /// Against the main deck; nil when the main deck's BPM is unknown.
    public let bpm: BPMMatch?

    public var id: Int64 { track.id }
}

public enum TrackSuggester {
    /// Library tracks that mix well after the main deck.
    ///
    /// A candidate must be in one of the main key's recommended keys and, when the main BPM is known, within
    /// the green BPM threshold (half / double time allowed). Excluded ids (loaded or already played tonight)
    /// are skipped. The result takes one track per recommended key in recommendation order, round after round,
    /// so it shows variety. Within a key, tracks that match at their own tempo come before half / double time
    /// matches (a 62 BPM hip-hop track is usually followed by another at ~62, not by 124 BPM house), then the
    /// smallest pitch change in half-percent steps, then the most played.
    public static func suggest(
        from candidates: [LibraryTrack],
        mainKey: MusicalKey,
        mainBPM: Double?,
        thresholds: BPMThresholds = BPMThresholds(),
        includeAdvanced: Bool = false,
        excluding excluded: Set<Int64> = [],
        limit: Int = 3
    ) -> [TrackSuggestion] {
        let recommendations = HarmonicRecommender.recommendations(for: mainKey, includeAdvanced: includeAdvanced)
        let relationByKey = Dictionary(recommendations.map { ($0.key, $0.relation) }, uniquingKeysWith: { first, _ in first })

        var byKey: [MusicalKey: [TrackSuggestion]] = [:]
        for track in candidates where !excluded.contains(track.id) {
            guard let key = track.key, let relation = relationByKey[key] else { continue }
            var match: BPMMatch?
            if let mainBPM {
                guard let found = BPMCompat.match(base: mainBPM, other: track.bpm, thresholds: thresholds),
                      found.level == .compatible
                else { continue }
                match = found
            }
            byKey[key, default: []].append(TrackSuggestion(track: track, relation: relation, bpm: match))
        }
        for (key, list) in byKey {
            byKey[key] = list.sorted(by: isBetter)
        }

        var result: [TrackSuggestion] = []
        var round = 0
        while result.count < limit {
            var added = false
            for recommendation in recommendations {
                guard let list = byKey[recommendation.key], round < list.count else { continue }
                result.append(list[round])
                added = true
                if result.count == limit { break }
            }
            guard added else { break }
            round += 1
        }
        return result
    }

    private static func isBetter(_ a: TrackSuggestion, _ b: TrackSuggestion) -> Bool {
        let halfOrDoubleA = a.bpm.map { $0.ratio != .normal } ?? false
        let halfOrDoubleB = b.bpm.map { $0.ratio != .normal } ?? false
        if halfOrDoubleA != halfOrDoubleB { return !halfOrDoubleA }
        let stepA = (abs(a.bpm?.pitchPercent ?? 0) * 2).rounded()
        let stepB = (abs(b.bpm?.pitchPercent ?? 0) * 2).rounded()
        if stepA != stepB { return stepA < stepB }
        if a.track.playCount != b.track.playCount { return a.track.playCount > b.track.playCount }
        return a.track.id < b.track.id
    }
}
