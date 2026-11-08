import XCTest
@testable import Domain

final class BPMCompatTests: XCTestCase {
    private func match(_ base: Double?, _ other: Double?, _ thresholds: BPMThresholds = BPMThresholds()) -> BPMMatch? {
        BPMCompat.match(base: base, other: other, thresholds: thresholds)
    }

    func testSameTempo() {
        XCTAssertEqual(match(124, 124), BPMMatch(ratio: .normal, pitchPercent: 0, level: .compatible))
    }

    func testPitchIsWhatTheOtherDeckNeeds() throws {
        let slower = try XCTUnwrap(match(124, 126))
        XCTAssertEqual(slower.pitchPercent, -1.587, accuracy: 0.001, "126 must slow down to reach 124")
        XCTAssertEqual(slower.ratio, .normal)
        XCTAssertEqual(try XCTUnwrap(match(126, 124)).pitchPercent, 1.613, accuracy: 0.001)
    }

    func testHalfAndDoubleTime() throws {
        XCTAssertEqual(match(70, 140), BPMMatch(ratio: .half, pitchPercent: 0, level: .compatible))
        XCTAssertEqual(match(140, 70), BPMMatch(ratio: .double, pitchPercent: 0, level: .compatible))
        // Serato often analyses hip-hop at half time.
        let halfAnalysed = try XCTUnwrap(match(124, 62.5))
        XCTAssertEqual(halfAnalysed.ratio, .double)
        XCTAssertEqual(halfAnalysed.pitchPercent, -0.8, accuracy: 0.001)
        XCTAssertEqual(halfAnalysed.level, .compatible)
    }

    func testThresholds() {
        XCTAssertEqual(match(106, 100)?.level, .compatible, "exactly +6% is still green")
        XCTAssertEqual(match(100, 106.5)?.level, .stretch)
        XCTAssertEqual(match(100, 94)?.level, .stretch)
        XCTAssertEqual(match(110, 100)?.level, .stretch, "exactly +10% is still yellow")
        XCTAssertEqual(match(100, 112)?.level, .incompatible)
        XCTAssertEqual(match(100, 112, BPMThresholds(compatible: 8, stretch: 12))?.level, .stretch)
    }

    func testFarApartTempos() {
        XCTAssertEqual(match(124, 140)?.level, .incompatible)
        XCTAssertEqual(match(124, 140)?.ratio, .normal)
    }

    func testMissingOrInvalidBPM() {
        XCTAssertNil(match(nil, 120))
        XCTAssertNil(match(120, nil))
        XCTAssertNil(match(0, 120))
        XCTAssertNil(match(120, -1))
    }
}
