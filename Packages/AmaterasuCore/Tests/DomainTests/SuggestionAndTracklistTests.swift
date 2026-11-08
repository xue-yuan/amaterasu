import Foundation
import XCTest
@testable import Domain

final class TrackSuggesterTests: XCTestCase {
    private func key(_ camelot: String) -> MusicalKey { KeyParser.parse(camelot)! }

    private func track(_ id: Int64, _ camelot: String, _ bpm: Double?, plays: Int = 0) -> LibraryTrack {
        LibraryTrack(id: id, title: "T\(id)", artist: "A", bpm: bpm, key: KeyParser.parse(camelot), playCount: plays)
    }

    func testOnlyCompatibleKeysAndTempos() {
        let suggestions = TrackSuggester.suggest(
            from: [track(1, "8A", 124), track(2, "6A", 124), track(3, "9A", 140), track(4, "9A", 62), track(5, "8B", 200)],
            mainKey: key("8A"), mainBPM: 124, limit: 10
        )
        XCTAssertEqual(Set(suggestions.map(\.track.id)), [1, 4], "6A is not recommended; 140 and 200 BPM are too far")
        XCTAssertEqual(suggestions.last?.bpm?.ratio, .double)
    }

    func testExcludedTracksAreSkipped() {
        let suggestions = TrackSuggester.suggest(from: [track(1, "8A", 124), track(2, "8A", 124)], mainKey: key("8A"), mainBPM: 124, excluding: [1])
        XCTAssertEqual(suggestions.map(\.track.id), [2])
    }

    func testRotatesThroughRecommendedKeysForVariety() {
        let library = [
            track(1, "8A", 124), track(2, "8A", 124), track(3, "8A", 124),
            track(4, "9A", 124), track(5, "7A", 124), track(6, "8B", 124),
        ]
        let suggestions = TrackSuggester.suggest(from: library, mainKey: key("8A"), mainBPM: 124, limit: 5)
        XCTAssertEqual(suggestions.map(\.track.key?.camelot), ["8A", "9A", "7A", "8B", "8A"])
        XCTAssertEqual(suggestions.first?.relation, .same)
    }

    func testWithinAKeySmallestPitchChangeThenMostPlayed() {
        let library = [track(1, "8A", 128), track(2, "8A", 124.2), track(3, "8A", 124, plays: 9)]
        let suggestions = TrackSuggester.suggest(from: library, mainKey: key("8A"), mainBPM: 124, limit: 3)
        XCTAssertEqual(suggestions.map(\.track.id), [3, 2, 1])
    }

    func testSameTempoComesBeforeHalfOrDoubleTime() {
        // Main deck at 62 (hip-hop analysed at half time): a 124 BPM track matches at ×½ with 0%,
        // but a 63 BPM track at its own tempo is the more natural next track.
        let library = [track(1, "1A", 124, plays: 9), track(2, "1A", 63)]
        let suggestions = TrackSuggester.suggest(from: library, mainKey: key("1A"), mainBPM: 62, limit: 2)
        XCTAssertEqual(suggestions.map(\.track.id), [2, 1])
    }

    func testWithoutAMainBPMOnlyTheKeyCounts() {
        let suggestions = TrackSuggester.suggest(from: [track(1, "8A", 200), track(2, "8A", nil)], mainKey: key("8A"), mainBPM: nil, limit: 5)
        XCTAssertEqual(suggestions.count, 2)
        XCTAssertNil(suggestions.first?.bpm)
    }
}

final class TracklistTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_967_000)

    private var tracks: [PlayedTrack] {
        [
            PlayedTrack(title: "Bodak Yellow", artist: "Cardi B", deck: 1, startedAt: t0),
            PlayedTrack(title: "BABY", artist: nil, deck: 2, startedAt: t0.addingTimeInterval(307)),
            PlayedTrack(title: nil, artist: nil, deck: 1, startedAt: t0.addingTimeInterval(3723)),
        ]
    }

    func testWithTimesFromTheFirstTrack() {
        XCTAssertEqual(Tracklist.text(tracks, includeTimes: true), """
            00:00 Cardi B - Bodak Yellow
            05:07 BABY
            1:02:03 (Unknown track)
            """)
    }

    func testNumberedWithoutTimes() {
        XCTAssertEqual(Tracklist.text(tracks, includeTimes: false), """
            1. Cardi B - Bodak Yellow
            2. BABY
            3. (Unknown track)
            """)
    }

    func testUnknownTrackName() {
        XCTAssertEqual(Tracklist.text(tracks, includeTimes: false, unknown: "（未知曲目）"), """
            1. Cardi B - Bodak Yellow
            2. BABY
            3. （未知曲目）
            """)
    }

    func testEmpty() {
        XCTAssertEqual(Tracklist.text([], includeTimes: true), "")
    }
}
