import XCTest
@testable import Domain

final class HarmonicRecommenderTests: XCTestCase {
    private func key(_ camelot: String) -> MusicalKey {
        KeyParser.parse(camelot)!
    }

    private func summary(_ recommendations: [KeyRecommendation]) -> [String] {
        recommendations.map { "\($0.key.camelot) \($0.relation.rawValue)" }
    }

    func testOrderAndRelations() {
        XCTAssertEqual(summary(HarmonicRecommender.recommendations(for: key("8A"))), [
            "8A same", "9A adjacent", "7A adjacent", "8B relative", "10A energyBoost",
        ])
    }

    func testWrapsRoundTheWheel() {
        XCTAssertEqual(summary(HarmonicRecommender.recommendations(for: key("12B"))), [
            "12B same", "1B adjacent", "11B adjacent", "12A relative", "2B energyBoost",
        ])
        XCTAssertEqual(summary(HarmonicRecommender.recommendations(for: key("1A"))), [
            "1A same", "2A adjacent", "12A adjacent", "1B relative", "3A energyBoost",
        ])
        XCTAssertEqual(key("11A").shifted(by: 2), key("1A"))
    }

    func testAdvancedRecommendationsAreHiddenByDefault() {
        XCTAssertFalse(HarmonicRecommender.recommendations(for: key("8A")).contains { $0.relation.isAdvanced })
        XCTAssertEqual(summary(HarmonicRecommender.recommendations(for: key("8A"), includeAdvanced: true)).suffix(2), [
            "3A semitoneUp", "9B diagonal",
        ])
        XCTAssertEqual(summary(HarmonicRecommender.recommendations(for: key("8B"), includeAdvanced: true)).suffix(2), [
            "3B semitoneUp", "7A diagonal",
        ])
    }

    func testRulesHoldForAll24Keys() {
        for base in MusicalKey.all {
            let all = HarmonicRecommender.recommendations(for: base, includeAdvanced: true)
            XCTAssertEqual(all.count, 7, base.camelot)
            XCTAssertEqual(Set(all.map(\.key)).count, 7, "\(base.camelot): no duplicates")
            XCTAssertEqual(all.first?.key, base)
            for recommendation in all {
                let candidate = recommendation.key
                let steps = (candidate.number - base.number + 12) % 12
                switch recommendation.relation {
                case .same:
                    XCTAssertEqual(candidate, base)
                case .adjacent:
                    XCTAssertTrue(steps == 1 || steps == 11, base.camelot)
                    XCTAssertEqual(candidate.isMinor, base.isMinor)
                case .relative:
                    XCTAssertEqual(candidate.number, base.number)
                    XCTAssertNotEqual(candidate.isMinor, base.isMinor)
                    // Relative keys share their notes: the minor tonic is three semitones below the major.
                    let major = base.isMinor ? candidate : base
                    let minor = base.isMinor ? base : candidate
                    XCTAssertEqual((major.pitchClass - minor.pitchClass + 12) % 12, 3, base.camelot)
                case .energyBoost:
                    XCTAssertEqual(steps, 2, base.camelot)
                    XCTAssertEqual(candidate.isMinor, base.isMinor)
                case .semitoneUp:
                    XCTAssertEqual(candidate.pitchClass, (base.pitchClass + 1) % 12, "\(base.camelot): one semitone up")
                    XCTAssertEqual(candidate.isMinor, base.isMinor)
                case .diagonal:
                    XCTAssertNotEqual(candidate.isMinor, base.isMinor)
                    XCTAssertEqual(steps, base.isMinor ? 1 : 11, base.camelot)
                }
            }
        }
    }

    func testRelationOfAnotherDecksKey() {
        XCTAssertEqual(HarmonicRecommender.relation(from: key("8A"), to: key("9A")), .adjacent)
        XCTAssertEqual(HarmonicRecommender.relation(from: key("8A"), to: key("8B")), .relative)
        XCTAssertNil(HarmonicRecommender.relation(from: key("8A"), to: key("6A")), "energy boost only goes up")
        XCTAssertNil(HarmonicRecommender.relation(from: key("8A"), to: key("3A")))
        XCTAssertEqual(HarmonicRecommender.relation(from: key("8A"), to: key("3A"), includeAdvanced: true), .semitoneUp)
    }
}
