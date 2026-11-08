import Domain
import Foundation
import XCTest
@testable import SeratoDatabase

final class DeckTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_967_000)

    private func session(open: Bool = true) -> HistorySession {
        HistorySession(row: SQLRow(
            columns: ["id", "start_time", "end_time", "name"],
            values: [.integer(85), .integer(1_793_966_000), .integer(open ? -1 : 1_793_970_000), .text("2026/11/6")]
        ))
    }

    private func entry(
        _ id: Int64, deck: String, played: Int64 = 0, start: TimeInterval = 0, end: Int64 = -1,
        name: String = "Track", artist: String = "Artist", bpm: SQLValue = .real(124), key: String = "Am", keyValue: Int64 = 7
    ) -> SQLRow {
        SQLRow(
            columns: ["id", "deck", "played", "start_time", "end_time", "name", "artist", "bpm", "key", "key_value"],
            values: [.integer(id), .text(deck), .integer(played), .integer(Int64(t0.timeIntervalSince1970 + start)),
                     .integer(end), .text(name), .text(artist), bpm, .text(key), .integer(keyValue)]
        )
    }

    func testNoDecksWithoutAnOpenSession() {
        var tracker = DeckTracker()
        XCTAssertEqual(tracker.update(session: nil, entries: [entry(1, deck: "1")], now: t0), [])
        XCTAssertEqual(tracker.update(session: session(open: false), entries: [entry(1, deck: "1")], now: t0), [])
    }

    func testMapsAnEntryToADeck() throws {
        var tracker = DeckTracker()
        let decks = tracker.update(session: session(), entries: [entry(1, deck: "2", start: 5, name: " Bodak Yellow ", bpm: .real(62.5), keyValue: 8)], now: t0)
        let deck = try XCTUnwrap(decks.first)
        XCTAssertEqual(deck.id, 2)
        XCTAssertEqual(deck.title, "Bodak Yellow")
        XCTAssertEqual(deck.bpm, 62.5)
        XCTAssertEqual(deck.key?.camelot, "9A")
        XCTAssertEqual(deck.loadedAt, t0.addingTimeInterval(5))
        XCTAssertFalse(deck.hasStartedPlaying)
        XCTAssertNil(deck.playStartedAt)
    }

    func testEjectedDecksAndBadRowsAreSkipped() {
        var tracker = DeckTracker()
        let decks = tracker.update(session: session(), entries: [
            entry(1, deck: "1", end: 1_793_967_100),  // ejected
            entry(2, deck: "", name: "no deck"),
            entry(3, deck: "7", name: "deck out of range"),
            entry(4, deck: "3"),
        ], now: t0)
        XCTAssertEqual(decks.map(\.id), [3])
    }

    func testMissingValuesBecomeNil() throws {
        var tracker = DeckTracker()
        let deck = try XCTUnwrap(tracker.update(session: session(), entries: [
            entry(1, deck: "1", name: "", artist: "  ", bpm: .null, key: "", keyValue: -1),
        ], now: t0).first)
        XCTAssertNil(deck.title)
        XCTAssertNil(deck.artist)
        XCTAssertNil(deck.bpm)
        XCTAssertNil(deck.key)
    }

    func testKeyStringIsTheFallbackForAMissingKeyValue() {
        var tracker = DeckTracker()
        let decks = tracker.update(session: session(), entries: [entry(1, deck: "1", key: "G#m", keyValue: -1)], now: t0)
        XCTAssertEqual(decks.first?.key?.camelot, "1A")
    }

    func testPlaybackSeenStartingIsTimedWhenSeen() {
        var tracker = DeckTracker()
        _ = tracker.update(session: session(), entries: [entry(1, deck: "1", played: 0, start: 0)], now: t0)
        let started = t0.addingTimeInterval(12)
        let decks = tracker.update(session: session(), entries: [entry(1, deck: "1", played: 1, start: 0)], now: started)
        XCTAssertEqual(decks.first?.hasStartedPlaying, true)
        XCTAssertEqual(decks.first?.playStartedAt, started)

        // Later reads keep the remembered time.
        let later = tracker.update(session: session(), entries: [entry(1, deck: "1", played: 1, start: 0)], now: t0.addingTimeInterval(60))
        XCTAssertEqual(later.first?.playStartedAt, started)
    }

    func testAlreadyPlayingWhenFirstSeenUsesTheLoadTime() {
        var tracker = DeckTracker()
        let decks = tracker.update(session: session(), entries: [entry(1, deck: "1", played: 1, start: 30)], now: t0.addingTimeInterval(300))
        XCTAssertEqual(decks.first?.playStartedAt, t0.addingTimeInterval(30))
    }

    func testMainDeckFollowsTheLatestPlaybackStart() {
        var tracker = DeckTracker()
        // Deck 1 has been playing since before Amaterasu started; deck 2 is loaded, then started.
        _ = tracker.update(session: session(), entries: [
            entry(1, deck: "1", played: 1, start: 0), entry(2, deck: "2", played: 0, start: 100),
        ], now: t0.addingTimeInterval(110))
        let decks = tracker.update(session: session(), entries: [
            entry(1, deck: "1", played: 1, start: 0), entry(2, deck: "2", played: 1, start: 100),
        ], now: t0.addingTimeInterval(130))
        XCTAssertEqual(MainDeck.select(from: decks), 2)
    }

    func testNewestEntryPerDeckWinsOverOrphans() {
        var tracker = DeckTracker()
        // Like #3207/#3208: an orphan (played 0, end -1) and the real, newer row on the same deck.
        let decks = tracker.update(session: session(), entries: [
            entry(3207, deck: "2", played: 0, name: "Orphan"), entry(3208, deck: "2", played: 1, name: "Real"),
        ], now: t0)
        XCTAssertEqual(decks.map(\.title), ["Real"])
    }

    func testRepeatWarningForATrackThatPlayedEarlier() {
        var tracker = DeckTracker()
        let decks = tracker.update(session: session(), entries: [
            entry(1, deck: "1", played: 1, start: 0, end: Int64(t0.timeIntervalSince1970 + 200), name: "Bodak Yellow"),
            entry(2, deck: "2", played: 1, start: 100, end: Int64(t0.timeIntervalSince1970 + 600), name: "Other"),
            entry(3, deck: "1", played: 1, start: 600, name: "Bodak Yellow"),
        ], now: t0.addingTimeInterval(700))
        XCTAssertEqual(decks.first { $0.id == 1 }?.playedEarlierAt, t0)
        XCTAssertNil(decks.first { $0.id == 2 }?.playedEarlierAt)
    }

    func testAnEarlierPreviewIsNotARepeat() {
        var tracker = DeckTracker()
        let decks = tracker.update(session: session(), entries: [
            entry(1, deck: "2", played: 1, start: 0, end: Int64(t0.timeIntervalSince1970 + 18), name: "Bodak Yellow"),
            entry(2, deck: "1", played: 1, start: 600, name: "Bodak Yellow"),
        ], now: t0.addingTimeInterval(700))
        XCTAssertNil(decks.first?.playedEarlierAt, "18 s on a deck was a preview")
    }

    func testInstantDoublesAreNotARepeat() {
        var tracker = DeckTracker()
        // Deck 2 gets the track deck 1 is still playing: the earlier play has not finished.
        let decks = tracker.update(session: session(), entries: [
            entry(1, deck: "1", played: 1, start: 0, name: "Bodak Yellow"),
            entry(2, deck: "2", played: 1, start: 30, name: "Bodak Yellow"),
        ], now: t0.addingTimeInterval(40))
        XCTAssertEqual(decks.map(\.playedEarlierAt), [nil, nil])
    }

    func testLatestEntryPerDeckSkipsOrphanRows() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "amaterasu-orphan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try SQLiteDatabase(path: directory.appending(path: "t.sqlite").path, mode: .readWrite)
        try db.query("CREATE TABLE history_entry (id INTEGER PRIMARY KEY, session_id INTEGER, deck TEXT, played INTEGER, end_time INTEGER)")
        // Like #3207/#3208: an orphan (played 0, end -1) followed by the real row on the same deck.
        try db.query("INSERT INTO history_entry VALUES (3206, 85, '1', 1, -1), (3207, 85, '2', 0, -1), (3208, 85, '2', 1, -1), (3209, 84, '3', 1, -1)")
        let rows = try HistoryQueries.latestEntryPerDeck(db, sessionID: 85)
        XCTAssertEqual(rows.map { $0["id"] }, [.integer(3206), .integer(3208)])
    }
}
