import Foundation
import XCTest
@testable import Domain

final class SetAnalysisTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_967_000)

    private func track(_ minute: Double, _ bpm: Double?, _ camelot: String?, endMinute: Double? = nil) -> PlayedTrack {
        PlayedTrack(
            title: "T\(Int(minute))", artist: nil, deck: 1,
            startedAt: t0.addingTimeInterval(minute * 60),
            endedAt: endMinute.map { t0.addingTimeInterval($0 * 60) },
            bpm: bpm, key: camelot.flatMap(KeyParser.parse)
        )
    }

    func testFoldsIntoTheOctaveAroundACenter() {
        XCTAssertEqual(SetAnalysis.fold(62.5, around: 124), 125)
        XCTAssertEqual(SetAnalysis.fold(150.06, around: 74), 75.03)
        XCTAssertEqual(SetAnalysis.fold(124, around: 124), 124)
    }

    func testAHipHopSetStaysAtItsOwnTempo() throws {
        // Like 11/6: trap analysed at ~62–75, rap at 82–87, one track analysed at double (150).
        let analysis = SetAnalysis(tracks: [
            track(0, 62.5, "9A"), track(1, 70, "3A"), track(5, 150.06, "2A"), track(6, 74, "1A"),
            track(13, 86.7, "2A"), track(18, 82, "7A"), track(26, 65, "12A"),
        ])
        let tempos = analysis.tracks.compactMap { $0.bpm.map(analysis.setTempo) }
        XCTAssertEqual(tempos, [62.5, 70, 75.03, 74, 86.7, 82, 65])
        XCTAssertEqual(analysis.tempoRange, 62.5...86.7)
        XCTAssertLessThan(abs(try XCTUnwrap(analysis.biggestTempoJump?.percent)), 25, "no fake ±50% jumps")
    }

    func testAHouseSetDoublesHalfTimeAnalyses() {
        let analysis = SetAnalysis(tracks: [track(0, 124, "8A"), track(4, 62.5, "8A"), track(8, 126, "8A")])
        XCTAssertEqual(analysis.tracks.compactMap { $0.bpm.map(analysis.setTempo) }, [124, 125, 126])
    }

    func testClassifiesTransitions() {
        let analysis = SetAnalysis(tracks: [
            track(0, 124, "8A"), track(4, 124, "9A"),   // adjacent
            track(8, 124, "11A"),                        // +2: energy boost
            track(12, 124, "4B"),                        // jump
            track(16, 124, nil),                         // unknown
        ])
        XCTAssertEqual(analysis.transitions.map(\.kind), [.harmonic, .energyBoost, .keyJump, .unknownKey])
        XCTAssertEqual(analysis.transitions.first?.relation, .adjacent)
        XCTAssertEqual(analysis.count(.keyJump), 1)
        XCTAssertEqual(try XCTUnwrap(analysis.harmonicShare), 2.0 / 3.0, accuracy: 1e-9, "unknown keys are not counted")
    }

    func testTempoStatsUseTheSetScale() throws {
        let analysis = SetAnalysis(tracks: [track(0, 124, "8A"), track(3, 62.5, "8A"), track(6, 140, "8A")])
        XCTAssertEqual(analysis.tempoRange, 124...140)
        XCTAssertEqual(try XCTUnwrap(analysis.averageTempo), (124 + 125 + 140) / 3, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(analysis.transitions[0].tempoChangePercent), 0.806, accuracy: 0.001)
        XCTAssertEqual(analysis.biggestTempoJump?.trackIndex, 2)
        XCTAssertEqual(try XCTUnwrap(analysis.biggestTempoJump?.percent), 12, accuracy: 1e-9)
    }

    func testDurationRunsToTheLastEnd() throws {
        let finished = SetAnalysis(tracks: [track(0, 124, "8A", endMinute: 5), track(4, 124, "8A", endMinute: 9)])
        XCTAssertEqual(finished.duration, 9 * 60)
        XCTAssertEqual(try XCTUnwrap(finished.averageTrackDuration), 4.5 * 60)

        let live = SetAnalysis(tracks: [track(0, 124, "8A", endMinute: 5), track(4, 124, "8A")], now: t0.addingTimeInterval(7 * 60))
        XCTAssertEqual(live.duration, 7 * 60, "the last track counts until now")
    }

    func testATrackLeftOnTheDeckAfterItEndedDoesNotCount() {
        // The last track (4 min long) stayed loaded for an hour before Serato was closed.
        let last = PlayedTrack(
            title: "Last", artist: nil, deck: 1, startedAt: t0.addingTimeInterval(5 * 60),
            endedAt: t0.addingTimeInterval(65 * 60), bpm: 124, key: nil, length: 4 * 60
        )
        let analysis = SetAnalysis(tracks: [track(0, 124, "8A", endMinute: 5), last])
        XCTAssertEqual(analysis.duration, 9 * 60)
    }

    func testEmptySet() {
        let analysis = SetAnalysis(tracks: [])
        XCTAssertEqual(analysis.duration, 0)
        XCTAssertNil(analysis.tempoRange)
        XCTAssertNil(analysis.harmonicShare)
        XCTAssertNil(analysis.biggestTempoJump)
        XCTAssertNil(analysis.averageTrackDuration)
    }
}
