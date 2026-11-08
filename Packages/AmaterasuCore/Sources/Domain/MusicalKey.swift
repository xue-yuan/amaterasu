import Foundation

/// A musical key as a position on the Camelot wheel.
public struct MusicalKey: Hashable, Sendable {
    /// Camelot number, 1...12.
    public let number: Int
    /// true = A side (minor), false = B side (major).
    public let isMinor: Bool

    public init?(number: Int, isMinor: Bool) {
        guard (1...12).contains(number) else { return nil }
        self.number = number
        self.isMinor = isMinor
    }

    /// From the tonic's pitch class (C = 0, C♯/D♭ = 1, … B = 11) and mode. Any integer is accepted (mod 12).
    public init(pitchClass: Int, isMinor: Bool) {
        let tonic = (pitchClass % 12 + 12) % 12
        // A minor key sits on the same wheel number as its relative major, three semitones up.
        let major = isMinor ? (tonic + 3) % 12 : tonic
        // Each step round the wheel is a fifth (7 semitones); C major is 8B.
        self.number = (major * 7 % 12 + 7) % 12 + 1
        self.isMinor = isMinor
    }

    /// Serato's `key_value`: 0...11 = 1A...12A, 12...23 = 1B...12B; -1 (not analysed) and anything else is nil.
    public init?(seratoKeyValue value: Int) {
        switch value {
        case 0...11: self.init(number: value + 1, isMinor: true)
        case 12...23: self.init(number: value - 11, isMinor: false)
        default: return nil
        }
    }

    /// The tonic's pitch class: C = 0 … B = 11.
    public var pitchClass: Int {
        ((7 * (number - 8) - (isMinor ? 3 : 0)) % 12 + 12) % 12
    }

    /// Moves `steps` round the wheel on the same side, wrapping 12 → 1.
    public func shifted(by steps: Int) -> MusicalKey {
        MusicalKey(wheel: ((number - 1 + steps) % 12 + 12) % 12 + 1, isMinor: isMinor)
    }

    /// The relative major / minor: same number, other side.
    public var relative: MusicalKey {
        MusicalKey(wheel: number, isMinor: !isMinor)
    }

    /// For numbers already known to be 1...12.
    private init(wheel number: Int, isMinor: Bool) {
        self.number = number
        self.isMinor = isMinor
    }

    /// Every key: 1A…12A, then 1B…12B.
    public static let all: [MusicalKey] = [true, false].flatMap { minor in
        (1...12).map { MusicalKey(wheel: $0, isMinor: minor) }
    }

    /// Serato's `key_value` for this key: 1A…12A = 0…11, 1B…12B = 12…23.
    public var seratoKeyValue: Int {
        isMinor ? number - 1 : number + 11
    }

    /// e.g. `8A`
    public var camelot: String { "\(number)\(isMinor ? "A" : "B")" }

    /// Open Key is the Camelot wheel shifted by 7; `m` = minor, `d` = major. e.g. 8B (C) = `1d`.
    public var openKey: String { "\((number + 4) % 12 + 1)\(isMinor ? "m" : "d")" }

    /// e.g. `Am`, `C`, `F#m`
    public var traditional: String { (isMinor ? Self.minorNames : Self.majorNames)[number - 1] }

    public func formatted(_ notation: KeyNotation) -> String {
        switch notation {
        case .camelot: camelot
        case .openKey: openKey
        case .traditional: traditional
        }
    }

    private static let minorNames = ["Abm", "Ebm", "Bbm", "Fm", "Cm", "Gm", "Dm", "Am", "Em", "Bm", "F#m", "Dbm"]
    private static let majorNames = ["B", "F#", "Db", "Ab", "Eb", "Bb", "F", "C", "G", "D", "A", "E"]
}

public enum KeyNotation: String, CaseIterable, Codable, Sendable {
    case camelot
    case openKey
    case traditional
}
