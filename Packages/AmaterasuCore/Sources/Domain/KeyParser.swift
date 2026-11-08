import Foundation

/// Turns the key strings found in Serato and in audio-file tags into a `MusicalKey`.
///
/// Accepts Camelot (`8A`, `12b`), Open Key (`1m`, `10d`) and traditional names with any spelling of the
/// accidental and mode (`Am`, `A minor`, `Abm`, `G#m`, `B♭m`, `C`, `F# major`, `Ebmin`). Enharmonic
/// spellings give the same key (`G#m` = `Abm` = `1A`).
public enum KeyParser {
    public static func parse(_ text: String) -> MusicalKey? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let first = trimmed.first, first.isNumber {
            return parseWheel(trimmed)
        }
        return parseTraditional(trimmed)
    }

    /// Camelot `8A` / `8B`, or Open Key `1m` / `1d`.
    private static func parseWheel(_ text: String) -> MusicalKey? {
        let compact = text.filter { !$0.isWhitespace }
        guard let letter = compact.last, let number = Int(compact.dropLast()), (1...12).contains(number) else {
            return nil
        }
        switch letter {
        case "A", "a":
            return MusicalKey(number: number, isMinor: true)
        case "B", "b":
            return MusicalKey(number: number, isMinor: false)
        case "m", "M":
            return MusicalKey(number: openKeyToCamelot(number), isMinor: true)
        case "d", "D":
            return MusicalKey(number: openKeyToCamelot(number), isMinor: false)
        default:
            return nil
        }
    }

    /// Open Key is the Camelot wheel shifted by 7: 1d = C = 8B.
    private static func openKeyToCamelot(_ number: Int) -> Int {
        (number + 6) % 12 + 1
    }

    private static let naturals: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]

    /// A root letter, an optional accidental, then the mode: nothing / `M` / `maj` / `major` for major,
    /// `m` / `min` / `minor` for minor.
    private static func parseTraditional(_ text: String) -> MusicalKey? {
        var rest = Substring(text)
        guard let letter = rest.first.map({ Character($0.uppercased()) }), let natural = naturals[letter] else {
            return nil
        }
        rest = rest.dropFirst()

        var pitchClass = natural
        switch rest.first {
        case "#", "♯":
            pitchClass += 1
            rest = rest.dropFirst()
        case "b", "♭":
            pitchClass -= 1
            rest = rest.dropFirst()
        default:
            break
        }

        let mode = rest.trimmingCharacters(in: .whitespaces)
        let isMinor: Bool
        if mode.isEmpty || mode == "M" {
            isMinor = false
        } else {
            switch mode.lowercased() {
            case "m", "mi", "min", "minor": isMinor = true
            case "maj", "major": isMinor = false
            default: return nil
            }
        }
        return MusicalKey(pitchClass: pitchClass, isMinor: isMinor)
    }
}
