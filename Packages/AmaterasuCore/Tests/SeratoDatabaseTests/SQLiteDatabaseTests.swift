import Foundation
import XCTest
@testable import SeratoDatabase

final class SQLiteDatabaseTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "amaterasu-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private static let historyEntryColumns = """
        id INTEGER PRIMARY KEY AUTOINCREMENT, session_id INTEGER, deck TEXT, played INTEGER,
        start_time INTEGER, end_time INTEGER, name TEXT, artist TEXT, bpm REAL, key TEXT,
        key_value INTEGER, file_name TEXT, location_id INTEGER, portable_id TEXT, asset_id INTEGER, length_sec INTEGER
        """

    /// A fixture with the same tables and columns Amaterasu relies on, and fake data only.
    private func makeFixture(
        name: String = "fixture.sqlite",
        historyEntryColumns: String = historyEntryColumns,
        includeSessionTable: Bool = true
    ) throws -> (path: String, writer: SQLiteDatabase) {
        let path = directory.appending(path: name).path
        let writer = try SQLiteDatabase(path: path, mode: .readWrite)
        if includeSessionTable {
            try writer.query("CREATE TABLE history_session (id INTEGER PRIMARY KEY AUTOINCREMENT, start_time INTEGER, end_time INTEGER, name TEXT)")
        }
        try writer.query("CREATE TABLE history_entry (\(historyEntryColumns))")
        try writer.query("CREATE TABLE location (id INTEGER PRIMARY KEY, path TEXT)")
        try writer.query("CREATE TABLE asset (id INTEGER PRIMARY KEY, name TEXT, artist TEXT, bpm REAL, key_value INTEGER DEFAULT -1, dj_play_count INTEGER DEFAULT 0, is_missing INTEGER DEFAULT 0, is_corrupt INTEGER DEFAULT 0, portable_id TEXT)")
        return (path, writer)
    }

    func testSchemaCheckAcceptsObservedLayout() throws {
        let (path, _) = try makeFixture()
        let reader = try SQLiteDatabase(path: path, mode: .readOnly)
        XCTAssertTrue(try SeratoSchema.check(reader).isCompatible)
    }

    func testSchemaCheckReportsMissingTableAndColumn() throws {
        let columns = Self.historyEntryColumns.replacingOccurrences(of: "key_value INTEGER, ", with: "")
        let (path, _) = try makeFixture(historyEntryColumns: columns, includeSessionTable: false)
        let report = try SeratoSchema.check(try SQLiteDatabase(path: path, mode: .readOnly))
        XCTAssertFalse(report.isCompatible)
        XCTAssertEqual(report.missingTables, ["history_session"])
        XCTAssertEqual(report.missingColumns, ["history_entry": ["key_value"]])
    }

    func testReadOnlyConnectionRejectsWrites() throws {
        let (path, _) = try makeFixture()
        let reader = try SQLiteDatabase(path: path, mode: .readOnly)
        XCTAssertThrowsError(try reader.query("INSERT INTO location (id, path) VALUES (1, '')"))
    }

    func testReadWriteIsRefusedForSeratosOwnDatabase() {
        XCTAssertThrowsError(try SQLiteDatabase(path: SeratoLibrary.databaseURL.path, mode: .readWrite)) { error in
            XCTAssertEqual((error as? SQLiteError)?.message.hasPrefix("refusing"), true)
        }
    }

    func testQueryRoundTripsValueTypes() throws {
        let (_, db) = try makeFixture()
        try db.query("CREATE TABLE sample (a, b, c, d, e)")
        let blob = Data([0x00, 0xFF, 0x10])
        try db.query("INSERT INTO sample VALUES (?, ?, ?, ?, ?)", [.null, .integer(42), .real(62.5), .text("Bodak Yellow ✓"), .blob(blob)])
        let row = try XCTUnwrap(db.query("SELECT * FROM sample").first)
        XCTAssertEqual(row["a"], .null)
        XCTAssertEqual(row["b"], .integer(42))
        XCTAssertEqual(row["c"], .real(62.5))
        XCTAssertEqual(row["d"], .text("Bodak Yellow ✓"))
        XCTAssertEqual(row["e"], .blob(blob))
        XCTAssertEqual(row["missing"], .null)
    }

    /// Mirrors the real setup: a WAL-mode writer (Serato) and our read-only reader.
    func testReadOnlyReaderSeesWALCommitsThroughDataVersion() throws {
        let (path, writer) = try makeFixture()
        try writer.query("PRAGMA journal_mode=WAL")
        try writer.query("INSERT INTO history_session (start_time, name) VALUES (1000, 'test')")

        let reader = try SQLiteDatabase(path: path, mode: .readOnly)
        let before = try reader.dataVersion()
        XCTAssertEqual(try reader.dataVersion(), before, "no commit in between")

        try writer.query("INSERT INTO history_entry (session_id, deck, played, start_time, end_time, name) VALUES (1, '1', 0, 1001, -1, 'Track')")
        XCTAssertNotEqual(try reader.dataVersion(), before)
        let rows = try HistoryQueries.entryRows(reader, sessionID: 1)
        XCTAssertEqual(rows.map { $0["name"] }, [.text("Track")])
    }

    func testSnapshotIncludesUncheckpointedWALAndIsDeletedOnRelease() throws {
        let (path, writer) = try makeFixture()
        try writer.query("PRAGMA journal_mode=WAL")
        try writer.query("PRAGMA wal_autocheckpoint=0")
        try writer.query("INSERT INTO history_session (start_time, name) VALUES (1000, 'only in wal')")

        var snapshot: SQLiteDatabase? = try SeratoLibrary.openSnapshot(of: URL(fileURLWithPath: path))
        let copyDirectory = URL(fileURLWithPath: try XCTUnwrap(snapshot).path).deletingLastPathComponent()
        XCTAssertEqual(try HistoryQueries.sessions(XCTUnwrap(snapshot), limit: 1).first?.name, "only in wal")

        snapshot = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: copyDirectory.path))
    }

    func testOpenSessionHasNoEndTime() throws {
        let (_, db) = try makeFixture()
        try db.query("INSERT INTO history_session (start_time, end_time, name) VALUES (1000, 2000, 'ended')")
        try db.query("INSERT INTO history_session (start_time, end_time, name) VALUES (3000, -1, 'open')")
        let sessions = try HistoryQueries.sessions(db, limit: 2)
        XCTAssertEqual(sessions.map(\.name), ["open", "ended"])
        XCTAssertEqual(sessions.map(\.isOpen), [true, false])
    }

    func testFilePathJoinsLocationAndPortableID() {
        let entry = SQLRow(columns: ["location_id", "portable_id"], values: [.integer(1), .text("Users/dj/Music/a.mp3")])
        XCTAssertEqual(HistoryQueries.filePath(of: entry, locations: [1: ""]), "/Users/dj/Music/a.mp3")
        XCTAssertEqual(HistoryQueries.filePath(of: entry, locations: [1: "/Volumes/USB/"]), "/Volumes/USB/Users/dj/Music/a.mp3")
        XCTAssertNil(HistoryQueries.filePath(of: SQLRow(columns: [], values: []), locations: [:]))
        let streaming = SQLRow(columns: ["location_id", "portable_id"], values: [.integer(2), .text("streaming://spotify/abc")])
        XCTAssertNil(HistoryQueries.filePath(of: streaming, locations: [2: ""]))
    }
}
