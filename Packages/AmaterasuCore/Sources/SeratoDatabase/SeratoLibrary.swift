import Foundation

/// Where Serato DJ Pro 4 keeps its data, and how to open it safely.
public enum SeratoLibrary {
    public static let bundleIdentifier = "com.serato.seratodj"

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// `~/Library/Application Support/Serato/Library`
    public static var libraryDirectory: URL {
        home.appending(path: "Library/Application Support/Serato/Library", directoryHint: .isDirectory)
    }

    /// `~/Library/Application Support/Serato/Library/master.sqlite` (WAL mode while Serato runs).
    public static var databaseURL: URL {
        libraryDirectory.appending(path: "master.sqlite", directoryHint: .notDirectory)
    }

    /// `~/Music/_Serato_/Logs`; `DJ.INFO` there links to the current session's log file.
    public static var logsDirectory: URL {
        home.appending(path: "Music/_Serato_/Logs", directoryHint: .isDirectory)
    }

    public static func walURL(for database: URL) -> URL {
        URL(fileURLWithPath: database.path + "-wal")
    }

    /// Opens the live database read-only.
    ///
    /// Requires Serato to be running: its `-wal` file must exist. Without it a read-only connection
    /// cannot open a WAL-mode database, and we must not create files next to Serato's database.
    public static func openLive(_ database: URL = databaseURL) throws -> SQLiteDatabase {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: database.path) else {
            throw SeratoLibraryError.databaseNotFound(database)
        }
        guard fileManager.fileExists(atPath: walURL(for: database).path) else {
            throw SeratoLibraryError.walNotFound(database)
        }
        return try SQLiteDatabase(path: database.path, mode: .readOnly)
    }

    static func isInsideLibraryDirectory(_ path: String) -> Bool {
        let target = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let library = libraryDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        return target == library || target.hasPrefix(library + "/")
    }
}

public enum SeratoLibraryError: Error, CustomStringConvertible {
    case databaseNotFound(URL)
    /// No `-wal` file next to the database, which normally means Serato is not running.
    case walNotFound(URL)

    public var description: String {
        switch self {
        case .databaseNotFound(let url):
            return "Serato database not found at \(url.path)"
        case .walNotFound(let url):
            return "no \(url.lastPathComponent)-wal next to the database (Serato not running?)"
        }
    }
}

extension SeratoLibrary {
    /// Opens a private copy of a database (plus its `-wal`, if present) in a temporary folder.
    /// The copy is deleted when the returned connection is released.
    /// Use this to inspect the library while Serato is not running.
    public static func openSnapshot(of source: URL = databaseURL) throws -> SQLiteDatabase {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path) else {
            throw SeratoLibraryError.databaseNotFound(source)
        }
        removeStaleSnapshots()
        let directory = fileManager.temporaryDirectory
            .appending(path: "\(snapshotPrefix)\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let removeDirectory = { try? FileManager.default.removeItem(at: directory) }
        do {
            let copy = directory.appending(path: source.lastPathComponent, directoryHint: .notDirectory)
            try fileManager.copyItem(at: source, to: copy)
            let wal = walURL(for: source)
            if fileManager.fileExists(atPath: wal.path) {
                try fileManager.copyItem(at: wal, to: walURL(for: copy))
            }
            return try SQLiteDatabase(path: copy.path, mode: .readWrite, onClose: { _ = removeDirectory() })
        } catch {
            _ = removeDirectory()
            throw error
        }
    }

    private static let snapshotPrefix = "amaterasu-snapshot-"

    /// Copies left behind by a process that was killed before releasing its connection (they are ~80 MB each).
    static func removeStaleSnapshots(olderThan age: TimeInterval = 10 * 60) {
        let fileManager = FileManager.default
        let temporary = fileManager.temporaryDirectory
        guard let names = try? fileManager.contentsOfDirectory(atPath: temporary.path) else { return }
        for name in names where name.hasPrefix(snapshotPrefix) {
            let url = temporary.appending(path: name, directoryHint: .isDirectory)
            let created = (try? fileManager.attributesOfItem(atPath: url.path))?[.creationDate] as? Date
            if let created, Date().timeIntervalSince(created) > age {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}
