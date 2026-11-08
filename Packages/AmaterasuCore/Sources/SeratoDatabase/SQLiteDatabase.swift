import Foundation
import SQLite3

/// A single SQLite value as returned by a query.
public enum SQLValue: Equatable, Sendable, CustomStringConvertible {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public var int64: Int64? {
        if case .integer(let value) = self { return value }
        return nil
    }

    public var double: Double? {
        switch self {
        case .real(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }

    public var string: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    public var description: String {
        switch self {
        case .null: return "NULL"
        case .integer(let value): return String(value)
        case .real(let value): return String(value)
        case .text(let value): return "\"\(value)\""
        case .blob(let data): return "<\(data.count) bytes>"
        }
    }
}

public struct SQLRow: Equatable, Sendable {
    public let columns: [String]
    public let values: [SQLValue]

    public init(columns: [String], values: [SQLValue]) {
        self.columns = columns
        self.values = values
    }

    /// The value of the named column, or `.null` when the row has no such column.
    public subscript(column: String) -> SQLValue {
        guard let index = columns.firstIndex(of: column) else { return .null }
        return values[index]
    }
}

public struct SQLiteError: Error, Equatable, CustomStringConvertible {
    public let code: Int32
    public let message: String

    public var description: String { "SQLite error \(code): \(message)" }
}

/// A thin wrapper over one SQLite connection. Not thread-safe: use it from a single thread or actor.
public final class SQLiteDatabase {
    public enum Mode: Sendable {
        /// Read-only; safe to use next to a live writer such as Serato. Never writes to the database.
        case readOnly
        /// Read-write. Only for private copies and test fixtures; refused for anything inside Serato's library folder.
        case readWrite
    }

    public let path: String
    private let handle: OpaquePointer
    private let onClose: (() -> Void)?

    public convenience init(path: String, mode: Mode) throws {
        try self.init(path: path, mode: mode, onClose: nil)
    }

    /// `onClose` runs after the connection is closed (used to delete temporary copies).
    init(path: String, mode: Mode, onClose: (() -> Void)?) throws {
        if mode == .readWrite, SeratoLibrary.isInsideLibraryDirectory(path) {
            throw SQLiteError(code: SQLITE_PERM, message: "refusing to open Serato's own database read-write: \(path)")
        }

        var components = URLComponents()
        components.scheme = "file"
        components.path = path
        if mode == .readOnly {
            components.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        }
        guard let uri = components.string else {
            throw SQLiteError(code: SQLITE_CANTOPEN, message: "invalid database path: \(path)")
        }

        let access = mode == .readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        var connection: OpaquePointer?
        let rc = sqlite3_open_v2(uri, &connection, access | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            sqlite3_close(connection)
            throw SQLiteError(code: rc, message: message)
        }

        self.path = path
        self.handle = connection
        self.onClose = onClose
        sqlite3_busy_timeout(connection, 250)
    }

    deinit {
        sqlite3_close(handle)
        onClose?()
    }

    /// Runs one statement and returns all of its rows.
    @discardableResult
    public func query(_ sql: String, _ parameters: [SQLValue] = []) throws -> [SQLRow] {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else { throw lastError(rc) }
        defer { sqlite3_finalize(statement) }

        for (offset, value) in parameters.enumerated() {
            try bind(value, at: Int32(offset + 1), in: statement)
        }

        let columnCount = sqlite3_column_count(statement)
        let columns = (0..<columnCount).map { String(cString: sqlite3_column_name(statement, $0)) }
        var rows: [SQLRow] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw lastError(step) }
            let values = (0..<columnCount).map { value(at: $0, in: statement) }
            rows.append(SQLRow(columns: columns, values: values))
        }
        return rows
    }

    /// Runs `body` inside a single read transaction so every query in it sees the same snapshot.
    /// Keep `body` short: an open read transaction holds back the writer's WAL checkpoint.
    public func readTransaction<T>(_ body: () throws -> T) throws -> T {
        try query("BEGIN")
        do {
            let result = try body()
            try query("COMMIT")
            return result
        } catch {
            _ = try? query("ROLLBACK")
            throw error
        }
    }

    /// `PRAGMA data_version`: changes whenever another connection has committed since the last call.
    public func dataVersion() throws -> Int64 {
        try query("PRAGMA data_version").first?.values.first?.int64 ?? 0
    }

    private func bind(_ value: SQLValue, at index: Int32, in statement: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let rc: Int32
        switch value {
        case .null:
            rc = sqlite3_bind_null(statement, index)
        case .integer(let v):
            rc = sqlite3_bind_int64(statement, index, v)
        case .real(let v):
            rc = sqlite3_bind_double(statement, index, v)
        case .text(let v):
            rc = sqlite3_bind_text(statement, index, v, -1, transient)
        case .blob(let v):
            rc = v.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
        }
        guard rc == SQLITE_OK else { throw lastError(rc) }
    }

    private func value(at index: Int32, in statement: OpaquePointer) -> SQLValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            return .text(String(cString: sqlite3_column_text(statement, index)))
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index))))
        default:
            return .null
        }
    }

    private func lastError(_ code: Int32) -> SQLiteError {
        SQLiteError(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }
}
