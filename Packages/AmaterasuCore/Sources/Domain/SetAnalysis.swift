import Foundation

/// How one track led into the next.
public struct SetTransition: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        /// Same key, adjacent, relative or diagonal.
        case harmonic
        /// +2, or +7 (a semitone up).
        case energyBoost
        /// Both keys known, but not a recommended move.
        case keyJump
        /// A key is missing.
        case unknownKey
    }

    public let relation: KeyRelation?
    public let kind: Kind
    /// Change of the set tempo (see `SetAnalysis.setTempo`) from the previous track, in percent.
    public let tempoChangePercent: Double?
}

/// What happened over a set, from Serato's BPM / Key analysis and the play history only.
public struct SetAnalysis: Equatable, Sendable {
    public struct TempoJump: Equatable, Sendable {
        /// The track the jump leads into.
        public let trackIndex: Int
        public let percent: Double
    }

    public let tracks: [PlayedTrack]
    /// `transitions[i]` leads into `tracks[i + 1]`.
    public let transitions: [SetTransition]
    /// From the first track's start to when the last one stopped: its end (or `now` while it plays), but no
    /// later than its own length after it started. A track left on a deck after it finished is not playing.
    public let duration: TimeInterval
    /// The centre of the set's tempo octave (see `setTempo`); nil when no track has a BPM.
    public let tempoCenter: Double?
    /// Set tempos (see `setTempo`).
    public let tempoRange: ClosedRange<Double>?
    public let averageTempo: Double?
    /// Harmonic and energy-boost transitions among those where both keys are known (0…1).
    public let harmonicShare: Double?
    public let biggestTempoJump: TempoJump?

    public var averageTrackDuration: TimeInterval? {
        tracks.isEmpty ? nil : duration / Double(tracks.count)
    }

    public func count(_ kind: SetTransition.Kind) -> Int {
        transitions.filter { $0.kind == kind }.count
    }

    /// - Parameter now: for a set still in progress, the time to count the last track until.
    public init(tracks: [PlayedTrack], now: Date? = nil) {
        self.tracks = tracks
        let center = Self.bestCenter(for: tracks.compactMap(\.bpm))
        self.tempoCenter = center
        let setTempo = { (bpm: Double) in center.map { Self.fold(bpm, around: $0) } ?? bpm }

        var transitions: [SetTransition] = []
        for (previous, next) in zip(tracks, tracks.dropFirst()) {
            var relation: KeyRelation?
            let kind: SetTransition.Kind
            if let from = previous.key, let to = next.key {
                relation = HarmonicRecommender.relation(from: from, to: to, includeAdvanced: true)
                switch relation {
                case .energyBoost?, .semitoneUp?: kind = .energyBoost
                case .some: kind = .harmonic
                case nil: kind = .keyJump
                }
            } else {
                kind = .unknownKey
            }
            var change: Double?
            if let from = previous.bpm.map(setTempo), let to = next.bpm.map(setTempo), from > 0 {
                change = (to - from) / from * 100
            }
            transitions.append(SetTransition(relation: relation, kind: kind, tempoChangePercent: change))
        }
        self.transitions = transitions

        if let first = tracks.first {
            let end = tracks.map { track in
                let left = track.endedAt ?? now ?? track.startedAt
                guard let length = track.length else { return left }
                return min(left, track.startedAt.addingTimeInterval(length))
            }.max() ?? first.startedAt
            duration = max(0, end.timeIntervalSince(first.startedAt))
        } else {
            duration = 0
        }

        let tempos = tracks.compactMap { $0.bpm.map(setTempo) }
        if let low = tempos.min(), let high = tempos.max() {
            tempoRange = low...high
            averageTempo = tempos.reduce(0, +) / Double(tempos.count)
        } else {
            tempoRange = nil
            averageTempo = nil
        }

        let known = transitions.filter { $0.kind != .unknownKey }
        harmonicShare = known.isEmpty ? nil : Double(known.filter { $0.kind != .keyJump }.count) / Double(known.count)

        biggestTempoJump = transitions.enumerated()
            .compactMap { index, transition in
                transition.tempoChangePercent.map { TempoJump(trackIndex: index + 1, percent: $0) }
            }
            .max { abs($0.percent) < abs($1.percent) }
    }

    /// A BPM on this set's tempo scale: doubled or halved into the octave around `tempoCenter`, so a
    /// half-time analysis (62.5) and the same groove at full tempo (125) line up.
    public func setTempo(_ bpm: Double) -> Double {
        tempoCenter.map { Self.fold(bpm, around: $0) } ?? bpm
    }

    /// `bpm` doubled or halved into the octave [center / √2, center × √2).
    public static func fold(_ bpm: Double, around center: Double) -> Double {
        guard bpm > 0, bpm.isFinite, center > 0 else { return bpm }
        let low = center / 2.squareRoot()
        let high = center * 2.squareRoot()
        var tempo = bpm
        while tempo < low { tempo *= 2 }
        while tempo >= high { tempo /= 2 }
        return tempo
    }

    /// The octave that makes the set's tempo line smoothest: among the set's own BPMs as centres, the one
    /// with the least total change between consecutive tracks; on a tie, the one whose octave already holds
    /// the most BPMs as Serato analysed them (a hip-hop set stays around 60–90, a house set around 120–130).
    static func bestCenter(for bpms: [Double]) -> Double? {
        let tempos = bpms.filter { $0 > 0 && $0.isFinite }
        guard !tempos.isEmpty else { return nil }
        func score(_ center: Double) -> (cost: Double, unchanged: Int) {
            let folded = tempos.map { fold($0, around: center) }
            let cost = zip(folded, folded.dropFirst()).reduce(0) { $0 + abs(log($1.1 / $1.0)) }
            let unchanged = zip(tempos, folded).filter { $0 == $1 }.count
            return ((cost * 1e6).rounded() / 1e6, unchanged)
        }
        return Set(tempos).min { a, b in
            let sa = score(a), sb = score(b)
            if sa.cost != sb.cost { return sa.cost < sb.cost }
            if sa.unchanged != sb.unchanged { return sa.unchanged > sb.unchanged }
            return a < b
        }
    }
}
