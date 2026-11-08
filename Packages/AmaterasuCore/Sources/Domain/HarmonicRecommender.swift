import Foundation

/// How a candidate key relates to the current one on the Camelot wheel.
public enum KeyRelation: String, CaseIterable, Sendable {
    /// Same key.
    case same
    /// Number ±1, same letter.
    case adjacent
    /// Same number, other letter (relative major / minor).
    case relative
    /// Number +2, same letter: lifts the energy.
    case energyBoost
    /// Number +7, same letter: up one semitone. Advanced.
    case semitoneUp
    /// A → B with number +1, or B → A with number −1. Advanced.
    case diagonal

    public var label: String {
        switch self {
        case .same: "Same key"
        case .adjacent: "Adjacent"
        case .relative: "Relative"
        case .energyBoost: "Energy boost"
        case .semitoneUp: "Semitone up"
        case .diagonal: "Diagonal"
        }
    }

    /// Hidden unless the user turns on advanced recommendations.
    public var isAdvanced: Bool {
        self == .semitoneUp || self == .diagonal
    }
}

public struct KeyRecommendation: Equatable, Sendable {
    public let key: MusicalKey
    public let relation: KeyRelation

    public init(key: MusicalKey, relation: KeyRelation) {
        self.key = key
        self.relation = relation
    }
}

public enum HarmonicRecommender {
    /// Keys that mix well after `key`, best first:
    /// same → adjacent (+1, −1) → relative → energy boost (+2) → [advanced: semitone up (+7), diagonal].
    public static func recommendations(for key: MusicalKey, includeAdvanced: Bool = false) -> [KeyRecommendation] {
        var candidates = [
            KeyRecommendation(key: key, relation: .same),
            KeyRecommendation(key: key.shifted(by: 1), relation: .adjacent),
            KeyRecommendation(key: key.shifted(by: -1), relation: .adjacent),
            KeyRecommendation(key: key.relative, relation: .relative),
            KeyRecommendation(key: key.shifted(by: 2), relation: .energyBoost),
        ]
        if includeAdvanced {
            candidates.append(KeyRecommendation(key: key.shifted(by: 7), relation: .semitoneUp))
            candidates.append(KeyRecommendation(key: key.relative.shifted(by: key.isMinor ? 1 : -1), relation: .diagonal))
        }
        var seen = Set<MusicalKey>()
        return candidates.filter { seen.insert($0.key).inserted }
    }

    /// How `candidate` relates to `key`, if it is one of `key`'s recommendations.
    public static func relation(from key: MusicalKey, to candidate: MusicalKey, includeAdvanced: Bool = false) -> KeyRelation? {
        recommendations(for: key, includeAdvanced: includeAdvanced).first { $0.key == candidate }?.relation
    }
}
