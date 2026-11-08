import Foundation
import XCTest
@testable import SeratoDatabase

final class SeratoEnvironmentTests: XCTestCase {
    private var directory: URL!
    private var database: URL { directory.appending(path: "master.sqlite") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "amaterasu-env-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: database.path)
        try? FileManager.default.removeItem(at: directory)
    }

    /// A WAL-mode database like Serato's. Keep the returned writer alive to keep the `-wal` file, as a running
    /// Serato does.
    private func makeDatabase(withKeyValue: Bool = true) throws -> SQLiteDatabase {
        let writer = try SQLiteDatabase(path: database.path, mode: .readWrite)
        try writer.query("PRAGMA journal_mode=WAL")
        try writer.query("CREATE TABLE history_session (id INTEGER PRIMARY KEY, start_time INTEGER, end_time INTEGER, name TEXT)")
        let keyValue = withKeyValue ? "key_value INTEGER, " : ""
        try writer.query("""
            CREATE TABLE history_entry (id INTEGER PRIMARY KEY, session_id INTEGER, deck TEXT, played INTEGER,
            start_time INTEGER, end_time INTEGER, name TEXT, artist TEXT, bpm REAL, key TEXT, \(keyValue)
            file_name TEXT, location_id INTEGER, portable_id TEXT, asset_id INTEGER, length_sec INTEGER)
            """)
        try writer.query("CREATE TABLE location (id INTEGER PRIMARY KEY, path TEXT)")
        try writer.query("CREATE TABLE asset (id INTEGER PRIMARY KEY, name TEXT, artist TEXT, bpm REAL, key_value INTEGER DEFAULT -1, dj_play_count INTEGER DEFAULT 0, is_missing INTEGER DEFAULT 0, is_corrupt INTEGER DEFAULT 0, portable_id TEXT)")
        return writer
    }

    private func check(installed: Bool = true, running: Bool) -> SeratoStatus {
        SeratoEnvironment.check(database: database, isInstalled: installed, isRunning: running)
    }

    func testNotInstalled() {
        XCTAssertEqual(check(installed: false, running: false), .notInstalled)
    }

    func testInstalledButNoDatabase() {
        XCTAssertEqual(check(running: false), .databaseMissing)
    }

    func testNotAnSQLiteFile() throws {
        try Data("hello".utf8).write(to: database)
        XCTAssertEqual(check(running: false), .databaseUnreadable(reason: "not an SQLite database"))
    }

    func testUnreadableFile() throws {
        let writer = try makeDatabase()
        _ = writer
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: database.path)
        guard case .databaseUnreadable = check(running: false) else {
            return XCTFail("expected databaseUnreadable, got \(check(running: false))")
        }
    }

    func testReadableButSeratoNotRunning() throws {
        let writer = try makeDatabase()
        _ = writer
        XCTAssertEqual(check(running: false), .notRunning)
    }

    func testRunningButDatabaseNotOpenedYet() throws {
        // A database with no -wal file: Serato has launched but not opened its library yet.
        let writer = try SQLiteDatabase(path: database.path, mode: .readWrite)
        try writer.query("CREATE TABLE t (x)")
        XCTAssertEqual(check(running: true), .notRunning)
    }

    func testReady() throws {
        let writer = try makeDatabase()
        XCTAssertEqual(check(running: true), .ready)
        withExtendedLifetime(writer) {}
    }

    func testIncompatibleSchemaNamesWhatIsMissing() throws {
        let writer = try makeDatabase(withKeyValue: false)
        XCTAssertEqual(check(running: true), .incompatible(missing: ["history_entry.key_value"]))
        withExtendedLifetime(writer) {}
    }
}
