import Domain
import Foundation
import XCTest
@testable import SeratoDatabase

final class SessionHistoryTests: XCTestCase {
    private func entry(_ id: Int64, deck: String, played: Int64 = 1, start: Int64, end: Int64, name: String, asset: Int64) -> SQLRow {
        SQLRow(
            columns: ["id", "deck", "played", "start_time", "end_time", "name", "artist", "asset_id"],
            values: [.integer(id), .text(deck), .integer(played), .integer(start), .integer(end), .text(name), .text("Artist"), .integer(asset)]
        )
    }

    func testPlayedTracksInOrderWithoutUnplayedLoads() {
        let tracks = SessionHistory.playedTracks(from: [
            entry(2, deck: "2", start: 200, end: 400, name: "Second", asset: 2),
            entry(1, deck: "1", start: 100, end: 300, name: "First", asset: 1),
            entry(3, deck: "1", played: 0, start: 300, end: 350, name: "Previewed", asset: 3),
        ])
        XCTAssertEqual(tracks.map(\.title), ["First", "Second"])
        XCTAssertEqual(tracks.first?.startedAt, Date(timeIntervalSince1970: 100))
    }

    func testInstantDoublesCountOnce() {
        // Session #85: Bodak Yellow on deck 1, then doubled onto deck 2 while still playing.
        let tracks = SessionHistory.playedTracks(from: [
            entry(3201, deck: "1", start: 100, end: 148, name: "Bodak Yellow", asset: 125),
            entry(3202, deck: "2", start: 104, end: 423, name: "Bodak Yellow", asset: 125),
            entry(3203, deck: "1", start: 148, end: 417, name: "BABY", asset: 9),
        ])
        XCTAssertEqual(tracks.map(\.title), ["Bodak Yellow", "BABY"])
    }

    func testAReplayLaterIsListedAgain() {
        let tracks = SessionHistory.playedTracks(from: [
            entry(1, deck: "1", start: 100, end: 200, name: "Hit", asset: 1),
            entry(2, deck: "2", start: 190, end: 400, name: "Other", asset: 2),
            entry(3, deck: "1", start: 400, end: -1, name: "Hit", asset: 1),
        ])
        XCTAssertEqual(tracks.map(\.title), ["Hit", "Other", "Hit"])
    }

    func testPreviewsAreLeftOut() {
        let tracks = SessionHistory.playedTracks(from: [
            entry(1, deck: "1", start: 100, end: 400, name: "Set track", asset: 1),
            entry(2, deck: "2", start: 300, end: 318, name: "Preview", asset: 2),  // 18 s, like Just Wanna Rock on 11/6
            entry(3, deck: "2", start: 400, end: 430, name: "Exactly 30 s", asset: 3),
            entry(4, deck: "1", start: 430, end: -1, name: "Still playing", asset: 4),
        ])
        XCTAssertEqual(tracks.map(\.title), ["Set track", "Exactly 30 s", "Still playing"])
    }

    func testSummaryCollectsLoadedAssets() {
        let session = HistorySession(row: SQLRow(
            columns: ["id", "start_time", "end_time", "name"], values: [.integer(9), .integer(100), .integer(-1), .text("tonight")]
        ))
        let summary = SessionHistory.summary(of: session, entries: [
            entry(1, deck: "1", start: 100, end: 200, name: "A", asset: 11),
            entry(2, deck: "2", played: 0, start: 150, end: -1, name: "B", asset: 12),
        ])
        XCTAssertEqual(summary.assetIDs, [11, 12])
        XCTAssertTrue(summary.isOpen)
        XCTAssertEqual(summary.tracks.count, 1)
    }
}

final class LibraryQueriesTests: XCTestCase {
    func testCandidatesAreLocalAnalysedTracksInRange() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "amaterasu-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try SQLiteDatabase(path: directory.appending(path: "t.sqlite").path, mode: .readWrite)
        try db.query("""
            CREATE TABLE asset (id INTEGER PRIMARY KEY, name TEXT, artist TEXT, bpm REAL, key_value INTEGER,
            dj_play_count INTEGER, is_missing INTEGER, is_corrupt INTEGER, portable_id TEXT)
            """)
        try db.query("""
            INSERT INTO asset VALUES
              (1, 'In key, in range', 'A', 125, 7, 3, 0, 0, 'Users/dj/a.mp3'),
              (2, 'Half time', 'A', 62, 7, 0, 0, 0, 'Users/dj/b.mp3'),
              (3, 'Wrong key', 'A', 124, 0, 0, 0, 0, 'Users/dj/c.mp3'),
              (4, 'Too fast', 'A', 150, 7, 0, 0, 0, 'Users/dj/d.mp3'),
              (5, 'Streaming', 'A', 124, 7, 0, 0, 0, 'streaming://spotify/x'),
              (6, 'Missing file', 'A', 124, 7, 0, 1, 0, 'Users/dj/e.mp3')
            """)
        let am = try XCTUnwrap(MusicalKey(seratoKeyValue: 7))
        let tracks = try LibraryQueries.candidates(db, keys: [am], bpmRange: 117...132)
        XCTAssertEqual(tracks.map(\.title), ["In key, in range", "Half time"])
        XCTAssertEqual(tracks.first?.key, am)
        XCTAssertEqual(tracks.first?.playCount, 3)
        XCTAssertEqual(try LibraryQueries.candidates(db, keys: [am], bpmRange: nil).count, 3)
    }

    func testSeratoKeyValueRoundTrips() {
        for value in 0...23 {
            XCTAssertEqual(MusicalKey(seratoKeyValue: value)?.seratoKeyValue, value)
        }
    }
}
