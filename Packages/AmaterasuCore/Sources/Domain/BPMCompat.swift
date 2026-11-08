import Foundation

public struct BPMThresholds: Equatable, Sendable {
    /// Within this pitch change (%) the decks are compatible (green).
    public var compatible: Double
    /// Within this (%) they can be matched with a big pitch change (yellow); beyond it they are not (grey).
    public var stretch: Double

    public init(compatible: Double = 6, stretch: Double = 10) {
        self.compatible = compatible
        self.stretch = stretch
    }
}

public struct BPMMatch: Equatable, Sendable {
    /// How the other deck's BPM is read: as is, doubled (double time) or halved (half time).
    public enum Ratio: Equatable, Sendable {
        case normal
        case double
        case half

        public var factor: Double {
            switch self {
            case .normal: 1
            case .double: 2
            case .half: 0.5
            }
        }
    }

    public enum Level: Equatable, Sendable {
        case compatible
        case stretch
        case incompatible
    }

    public let ratio: Ratio
    /// The pitch change the other deck needs to match the base, in percent (e.g. +2.1).
    public let pitchPercent: Double
    public let level: Level
}

public enum BPMCompat {
    /// How the `other` deck's tempo can be matched to the `base` (main) deck.
    ///
    /// The other deck needs a pitch change of `p = base / (other × r) − 1`, where `r` is 1, 2 or ½ to allow
    /// double / half time (70 ↔ 140); the `r` with the smallest |p| wins, preferring 1 on a tie.
    /// Returns nil when either BPM is missing or not positive.
    public static func match(base: Double?, other: Double?, thresholds: BPMThresholds = BPMThresholds()) -> BPMMatch? {
        guard let base, let other, base > 0, other > 0 else { return nil }
        let candidates: [(ratio: BPMMatch.Ratio, percent: Double)] = [BPMMatch.Ratio.normal, .double, .half].map { ratio in
            (ratio, (base / (other * ratio.factor) - 1) * 100)
        }
        guard let best = candidates.min(by: { abs($0.percent) < abs($1.percent) }) else { return nil }

        // Tolerate floating-point noise exactly at a threshold.
        let size = abs(best.percent) - 1e-9
        let level: BPMMatch.Level
        if size <= thresholds.compatible {
            level = .compatible
        } else if size <= thresholds.stretch {
            level = .stretch
        } else {
            level = .incompatible
        }
        return BPMMatch(ratio: best.ratio, pitchPercent: best.percent, level: level)
    }
}
