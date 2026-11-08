import Domain
import Foundation
import XCTest
@testable import SeratoDatabase

/// End to end against a WAL database written the way Serato writes it. `poll()` is driven by hand (it
/// publishes synchronously), so the tests do not depend on the timer.
@MainActor
final class SeratoDatabaseProviderTests: XCTestCase {
    private var directory: URL!
    private var writer: SQLiteDatabase!
    private var database: URL { directory.appending(path: "master.sqlite") }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "amaterasu-provider-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        writer = try SQLiteDatabase(path: database.path, mode: .readWrite)
        try writer.query("PRAGMA journal_mode=WAL")
        try writer.query("CREATE TABLE history_session (id INTEGER PRIMARY KEY AUTOINCREMENT, start_time INTEGER, end_time INTEGER, name TEXT)")
        try writer.query("""
            CREATE TABLE history_entry (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id INTEGER, deck TEXT,
            played INTEGER DEFAULT 0, start_time INTEGER, end_time INTEGER DEFAULT -1, name TEXT, artist TEXT,
            bpm REAL, key TEXT, key_value INTEGER DEFAULT -1, asset_id INTEGER)
            """)
        try writer.query("CREATE TABLE asset (id INTEGER PRIMARY KEY, name TEXT, artist TEXT, bpm REAL, key_value INTEGER DEFAULT -1, dj_play_count INTEGER DEFAULT 0, is_missing INTEGER DEFAULT 0, is_corrupt INTEGER DEFAULT 0, portable_id TEXT)")
    }

    override func tearDown() async throws {
        writer = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeProvider() -> SeratoDatabaseProvider {
        SeratoDatabaseProvider(database: database, interval: .seconds(60))
    }

    func testFollowsLoadsPlaybackAndEjects() throws {
        let provider = makeProvider()
        provider.isSeratoRunning = true

        // Only an ended session: nothing on the decks.
        try writer.query("INSERT INTO history_session (start_time, end_time, name) VALUES (1000, 2000, 'old')")
        provider.poll()
        XCTAssertEqual(provider.lastPublished, [])

        // Serato opens a session and loads deck 1.
        try writer.query("INSERT INTO history_session (start_time, end_time, name) VALUES (3000, -1, 'now')")
        try writer.query("INSERT INTO history_entry (session_id, deck, start_time, name, artist, bpm, key, key_value) VALUES (2, '1', 3001, 'Money', 'Rico Nasty', 62, 'Abm', 0)")
        provider.poll()
        XCTAssertEqual(provider.lastPublished?.map(\.title), ["Money"])
        XCTAssertEqual(provider.lastPublished?.first?.key?.camelot, "1A")
        XCTAssertEqual(provider.lastPublished?.first?.hasStartedPlaying, false)

        // Playback starts.
        try writer.query("UPDATE history_entry SET played = 1 WHERE id = 1")
        provider.poll()
        XCTAssertEqual(provider.lastPublished?.first?.hasStartedPlaying, true)
        XCTAssertNotNil(provider.lastPublished?.first?.playStartedAt)

        // Deck 1 is ejected.
        try writer.query("UPDATE history_entry SET end_time = 3100 WHERE id = 1")
        provider.poll()
        XCTAssertEqual(provider.lastPublished, [])
        XCTAssertNil(provider.lastError)
    }

    func testPublishesThroughTheStream() async throws {
        try writer.query("INSERT INTO history_session (start_time, end_time, name) VALUES (3000, -1, 'now')")
        try writer.query("INSERT INTO history_entry (session_id, deck, start_time, name) VALUES (1, '2', 3001, 'Track')")
        let provider = makeProvider()
        var updates = provider.updates.makeAsyncIterator()
        provider.isSeratoRunning = true // reads at once
        XCTAssertEqual(provider.lastPublished?.map(\.id), [2])
        let first = await updates.next()
        XCTAssertEqual(first?.map(\.id), [2])
    }

    func testPicksUpAnalysisThatFinishesAfterLoading() throws {
        // Loaded before analysis: the history entry has no BPM or Key, and Serato never updates it.
        try writer.query("INSERT INTO asset (id, name, bpm, key_value, portable_id) VALUES (77, 'Ayo', NULL, -1, 'Users/dj/ayo.mp3')")
        try writer.query("INSERT INTO history_session (start_time, end_time, name) VALUES (3000, -1, 'now')")
        try writer.query("INSERT INTO history_entry (session_id, deck, start_time, name, asset_id) VALUES (1, '1', 3001, 'Ayo', 77)")
        let provider = makeProvider()
        provider.isSeratoRunning = true
        XCTAssertNil(provider.lastPublished?.first?.bpm)
        XCTAssertNil(provider.lastPublished?.first?.key)

        // Analysis finishes: only the library row changes.
        try writer.query("UPDATE asset SET bpm = 98, key_value = 1 WHERE id = 77")
        provider.poll()
        XCTAssertEqual(provider.lastPublished?.first?.bpm, 98)
        XCTAssertEqual(provider.lastPublished?.first?.key?.camelot, "2A")
    }

    func testLibraryValuesWinOverWhatWasRecordedAtLoad() throws {
        // Like "Just Wanna Rock": recorded at 75.03 BPM, since corrected to 150.06 in the library.
        try writer.query("INSERT INTO asset (id, name, bpm, key_value, portable_id) VALUES (5, 'Just Wanna Rock', 150.06, 1, 'Users/dj/jwr.m4a')")
        try writer.query("INSERT INTO history_session (start_time, end_time, name) VALUES (3000, -1, 'now')")
        try writer.query("INSERT INTO history_entry (session_id, deck, start_time, name, bpm, key_value, asset_id) VALUES (1, '1', 3001, 'Just Wanna Rock', 75.03, 1, 5), (1, '2', 3002, 'No asset', 120, 7, NULL)")
        let provider = makeProvider()
        provider.isSeratoRunning = true
        XCTAssertEqual(provider.lastPublished?.map(\.bpm), [150.06, 120], "deck 2 has no library row: the history value is used")
    }

    func testClearsDecksWhenSeratoQuits() throws {
        try writer.query("INSERT INTO history_session (start_time, end_time, name) VALUES (3000, -1, 'now')")
        try writer.query("INSERT INTO history_entry (session_id, deck, start_time, name) VALUES (1, '2', 3001, 'Track')")
        let provider = makeProvider()
        provider.isSeratoRunning = true
        XCTAssertEqual(provider.lastPublished?.map(\.id), [2])
        provider.isSeratoRunning = false
        XCTAssertEqual(provider.lastPublished, [])
    }

    func testSessionTracklistSurvivesSeratoQuitting() throws {
        try writer.query("INSERT INTO history_session (start_time, end_time, name) VALUES (3000, -1, '2026/11/7')")
        try writer.query("INSERT INTO history_entry (session_id, deck, played, start_time, end_time, name, artist) VALUES (1, '1', 1, 3001, 3200, 'A', 'X'), (1, '2', 1, 3150, -1, 'B', 'Y'), (1, '1', 0, 3200, -1, 'C', 'Z')")
        let provider = makeProvider()
        var reported: [SessionSummary?] = []
        provider.onSessionChange = { reported.append($0) }
        provider.isSeratoRunning = true
        XCTAssertEqual(provider.session?.tracks.map(\.title), ["A", "B"], "C was loaded but never played")
        XCTAssertEqual(reported.count, 1)

        provider.isSeratoRunning = false
        XCTAssertEqual(provider.lastPublished, [])
        XCTAssertEqual(provider.session?.tracks.count, 2, "kept for copying after Serato quits")
    }

    func testDoesNotReadWhileSeratoIsNotRunning() async throws {
        try writer.query("INSERT INTO history_session (start_time, end_time, name) VALUES (3000, -1, 'now')")
        try writer.query("INSERT INTO history_entry (session_id, deck, start_time, name) VALUES (1, '1', 3001, 'Track')")
        let provider = makeProvider()
        try await provider.start()
        provider.poll()
        XCTAssertEqual(provider.lastPublished, [], "only the initial empty state")
        provider.stop()
    }

    func testUnchangedFilesAreNotReadAgain() throws {
        try writer.query("INSERT INTO history_session (start_time, end_time, name) VALUES (3000, -1, 'now')")
        let provider = makeProvider()
        provider.isSeratoRunning = true
        let signature = DatabaseSignature(database: database)
        provider.poll()
        XCTAssertEqual(DatabaseSignature(database: database), signature, "reading does not touch the -wal or the database file")
    }
}
