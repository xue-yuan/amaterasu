import XCTest
@testable import Domain

final class KeyParserTests: XCTestCase {
    func testEveryKeyRoundTripsThroughEveryNotation() {
        for key in MusicalKey.all {
            XCTAssertEqual(KeyParser.parse(key.camelot), key, key.camelot)
            XCTAssertEqual(KeyParser.parse(key.openKey), key, key.openKey)
            XCTAssertEqual(KeyParser.parse(key.traditional), key, key.traditional)
        }
        XCTAssertEqual(Set(MusicalKey.all).count, 24)
    }

    func testPitchClassesAgreeWithTheCamelotTable() {
        for key in MusicalKey.all {
            XCTAssertEqual(MusicalKey(pitchClass: key.pitchClass, isMinor: key.isMinor), key, key.camelot)
        }
        XCTAssertEqual(MusicalKey(number: 8, isMinor: false)?.pitchClass, 0)  // C
        XCTAssertEqual(MusicalKey(number: 8, isMinor: true)?.pitchClass, 9)   // A
        XCTAssertEqual(MusicalKey(number: 1, isMinor: true)?.pitchClass, 8)   // Ab
    }

    func testEnharmonicSpellingsAreTheSameKey() {
        let pairs = [
            ("G#m", "Abm"), ("C#m", "Dbm"), ("D#m", "Ebm"), ("A#m", "Bbm"), ("F#m", "Gbm"),
            ("F#", "Gb"), ("C#", "Db"), ("G#", "Ab"), ("D#", "Eb"), ("A#", "Bb"),
            ("Cb", "B"), ("E#", "F"), ("B#", "C"), ("Fb", "E"),
        ]
        for (a, b) in pairs {
            XCTAssertNotNil(KeyParser.parse(a), a)
            XCTAssertEqual(KeyParser.parse(a), KeyParser.parse(b), "\(a) = \(b)")
        }
        XCTAssertEqual(KeyParser.parse("G#m")?.camelot, "1A")
    }

    func testSpellingVariants() {
        let expectations: [(String, String)] = [
            ("Am", "8A"), ("A minor", "8A"), ("a min", "8A"), ("Amin", "8A"), ("am", "8A"),
            ("C", "8B"), ("C major", "8B"), ("Cmaj", "8B"), ("CM", "8B"),
            ("F# major", "2B"), ("F♯", "2B"), ("B♭m", "3A"), ("Bbm", "3A"), ("bbm", "3A"), ("bm", "10A"),
            ("Ebmin", "2A"), ("Ab Minor", "1A"),
            (" 8A ", "8A"), ("8a", "8A"), ("08A", "8A"), ("12b", "12B"),
            ("1m", "8A"), ("1d", "8B"), ("6m", "1A"), ("12d", "7B"), ("10 m", "5A"),
        ]
        for (text, camelot) in expectations {
            XCTAssertEqual(KeyParser.parse(text)?.camelot, camelot, text)
        }
    }

    /// Every distinct `key` string in the development Serato library, against Serato's own `key_value`.
    func testMatchesSeratosNormalisation() {
        let serato: [(String, Int)] = [
            ("1A", 0), ("Abm", 0), ("G#m", 0), ("Ebm", 1), ("Bbm", 2), ("Fm", 3), ("5A", 4), ("Cm", 4),
            ("6A", 5), ("Gm", 5), ("Dm", 6), ("Am", 7), ("Em", 8), ("Bm", 9), ("F#m", 10), ("C#m", 11),
            ("Dbm", 11), ("1B", 12), ("B", 12), ("F#", 13), ("3B", 14), ("C#", 14), ("Db", 14), ("4B", 15),
            ("Ab", 15), ("Eb", 16), ("Bb", 17), ("F", 18), ("8B", 19), ("C", 19), ("G", 20), ("D", 21),
            ("11B", 22), ("A", 22), ("E", 23),
        ]
        for (text, value) in serato {
            XCTAssertEqual(KeyParser.parse(text), MusicalKey(seratoKeyValue: value), text)
        }
    }

    func testRejectsAnythingElse() {
        for text in ["", "  ", "—", "-", "?", "13A", "0B", "8C", "H", "Xm", "Am7", "A dorian", "Unknown", "o"] {
            XCTAssertNil(KeyParser.parse(text), "\"\(text)\"")
        }
    }
}
