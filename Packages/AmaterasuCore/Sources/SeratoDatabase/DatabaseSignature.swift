import Darwin
import Foundation

/// Size and nanosecond modification times of the `-wal` and the database file.
///
/// Serato's commits append to the WAL and its checkpoints write the database file; readers (including us)
/// touch neither, so a changed signature means Serato wrote something. Checking it needs no connection.
/// The `-shm` file is deliberately ignored: readers write to it too.
public struct DatabaseSignature: Equatable, Sendable {
    public let walSize: Int64
    public let walModified: Int64
    public let databaseModified: Int64

    /// nil when either file is missing (no `-wal` means Serato does not have the database open).
    public init?(database: URL) {
        guard let wal = Self.fileInfo(SeratoLibrary.walURL(for: database).path),
              let main = Self.fileInfo(database.path)
        else { return nil }
        walSize = wal.size
        walModified = wal.modified
        databaseModified = main.modified
    }

    private static func fileInfo(_ path: String) -> (size: Int64, modified: Int64)? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return (Int64(info.st_size), modified)
    }
}
