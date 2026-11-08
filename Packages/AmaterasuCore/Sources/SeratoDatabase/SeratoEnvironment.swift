import Foundation

/// Whether Amaterasu can read Serato right now, and if not, why.
public enum SeratoStatus: Equatable, Sendable {
    /// Serato DJ Pro is not installed.
    case notInstalled
    /// Installed, but there is no 4.x library database (never launched, or an older Serato).
    case databaseMissing
    /// The database exists but cannot be read (permissions, I/O, not an SQLite file).
    case databaseUnreadable(reason: String)
    /// Everything is in place; Serato is just not running.
    case notRunning
    /// Serato runs, but its database lacks tables / columns Amaterasu relies on (e.g. after a Serato update).
    case incompatible(missing: [String])
    /// Serato runs and its database is readable and compatible.
    case ready
}

public enum SeratoEnvironment {
    /// Checks, in order: installed → database present → readable → running → schema compatible.
    ///
    /// `isInstalled` / `isRunning` come from the caller (NSWorkspace) to keep AppKit out of this module.
    /// Opens the live database only while Serato runs, read-only, and closes it before returning.
    public static func check(
        database: URL = SeratoLibrary.databaseURL,
        isInstalled: Bool,
        isRunning: Bool
    ) -> SeratoStatus {
        guard isInstalled else { return .notInstalled }
        guard FileManager.default.fileExists(atPath: database.path) else { return .databaseMissing }

        // Reading the header proves the file is readable, and is where a macOS privacy prompt would appear.
        do {
            let handle = try FileHandle(forReadingFrom: database)
            defer { try? handle.close() }
            let header = try handle.read(upToCount: 16) ?? Data()
            guard header == Data("SQLite format 3\0".utf8) else {
                return .databaseUnreadable(reason: "not an SQLite database")
            }
        } catch {
            return .databaseUnreadable(reason: error.localizedDescription)
        }

        guard isRunning else { return .notRunning }
        do {
            let live = try SeratoLibrary.openLive(database)
            let report = try SeratoSchema.check(live)
            guard !report.isCompatible else { return .ready }
            let columns = report.missingColumns.keys.sorted().flatMap { table in
                (report.missingColumns[table] ?? []).map { "\(table).\($0)" }
            }
            return .incompatible(missing: report.missingTables + columns)
        } catch SeratoLibraryError.walNotFound {
            return .notRunning // Serato is starting and has not opened its database yet.
        } catch {
            return .databaseUnreadable(reason: "\(error)")
        }
    }
}
