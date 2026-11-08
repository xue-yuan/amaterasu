import Domain
import Foundation
import XCTest
@testable import SeratoDatabase

final class SessionArchiveTests: XCTestCase {
    private var directory: URL!
    private var database: URL { directory.appending(path: "master.sqlite") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "amaterasu-archive-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeDatabase(wal: Bool) throws -> SQLiteDatabase {
        let db = try SQLiteDatabase(path: database.path, mode: .readWrite)
        if wal { try db.query("PRAGMA journal_mode=WAL") }
        try db.query("CREATE TABLE history_session (id INTEGER PRIMARY KEY, start_time INTEGER, end_time INTEGER, name TEXT)")
        try db.query("""
            CREATE TABLE history_entry (id INTEGER PRIMARY KEY, session_id INTEGER, deck TEXT, played INTEGER,
            start_time INTEGER, end_time INTEGER, name TEXT, artist TEXT, bpm REAL, key TEXT, key_value INTEGER,
            asset_id INTEGER, portable_id TEXT)
            """)
        try db.query("CREATE TABLE asset (id INTEGER PRIMARY KEY, bpm REAL, key_value INTEGER)")
        try db.query("""
            INSERT INTO history_session VALUES (1, 1000, 2000, 'old'), (2, 3000, 4000, 'nothing played'), (3, 5000, -1, 'tonight')
            """)
        try db.query("""
            INSERT INTO history_entry VALUES
              (1, 1, '1', 1, 1000, 1300, 'A', 'X', 124, '', 7, 10, 'a'),
              (2, 1, '2', 1, 1010, 1500, 'A', 'X', 124, '', 7, 10, 'a'),
              (3, 1, '1', 1, 1300, 2000, 'B', 'Y', 75.03, '', 1, 11, 'b'),
              (4, 2, '1', 0, 3000, 3100, 'C', 'Z', 120, '', 7, 12, 'c'),
              (5, 3, '1', 1, 5000, -1, 'D', 'W', 128, '', 8, 13, 'd')
            """)
        // The library has since corrected B's tempo.
        try db.query("INSERT INTO asset VALUES (10, 124, 7), (11, 150.06, 1), (12, 120, 7), (13, 128, 8)")
        return db
    }

    func testListsSessionsWithPlayedTracksFromACopy() async throws {
        let writer = try makeDatabase(wal: false)
        withExtendedLifetime(writer) {}
        let archive = SessionArchive(database: database)
        let sessions = try await archive.sessions()
        XCTAssertEqual(sessions.map(\.name), ["tonight", "old"], "newest first; the empty session is left out")
        XCTAssertEqual(sessions.map(\.trackCount), [1, 2], "the instant double of A counts once")
        XCTAssertEqual(sessions.first?.isOpen, true)
        await archive.close()
    }

    func testTracksUseTheLibrarysCurrentAnalysis() async throws {
        let writer = try makeDatabase(wal: false)
        withExtendedLifetime(writer) {}
        let archive = SessionArchive(database: database)
        let tracks = try await archive.tracks(sessionID: 1)
        XCTAssertEqual(tracks.map(\.title), ["A", "B"])
        XCTAssertEqual(tracks.last?.bpm, 150.06)
        XCTAssertEqual(tracks.first?.endedAt, Date(timeIntervalSince1970: 1500), "the double extends A's play")
        await archive.close()
    }

    func testReadsTheLiveDatabaseWhileItIsOpen() async throws {
        let writer = try makeDatabase(wal: true) // keeps the -wal file, as a running Serato does
        let archive = SessionArchive(database: database)
        let before = try await archive.sessions()
        try writer.query("INSERT INTO history_entry VALUES (6, 3, '2', 1, 5100, -1, 'E', 'V', 128, '', 8, 14, 'e')")
        let after = try await archive.sessions()
        XCTAssertEqual(before.first?.trackCount, 1)
        XCTAssertEqual(after.first?.trackCount, 2, "no stale copy while live")
        withExtendedLifetime(writer) {}
    }
}
