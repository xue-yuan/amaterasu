import Foundation

/// The parts of Serato's private schema that Amaterasu relies on (observed in Serato DJ Pro 4.0.1).
public enum SeratoSchema {
    public struct Requirement: Sendable {
        public let table: String
        public let columns: [String]

        public init(table: String, columns: [String]) {
            self.table = table
            self.columns = columns
        }
    }

    public static let required: [Requirement] = [
        Requirement(table: "history_session", columns: ["id", "start_time", "end_time", "name"]),
        Requirement(table: "history_entry", columns: [
            "id", "session_id", "deck", "played", "start_time", "end_time",
            "name", "artist", "bpm", "key", "key_value",
            "file_name", "location_id", "portable_id", "asset_id", "length_sec",
        ]),
        Requirement(table: "location", columns: ["id", "path"]),
        Requirement(table: "asset", columns: [
            "id", "name", "artist", "bpm", "key_value", "dj_play_count", "is_missing", "is_corrupt", "portable_id",
        ]),
    ]

    public struct Report: Equatable, Sendable {
        public var missingTables: [String] = []
        public var missingColumns: [String: [String]] = [:]

        public var isCompatible: Bool { missingTables.isEmpty && missingColumns.isEmpty }
    }

    public static func check(_ database: SQLiteDatabase, requirements: [Requirement] = required) throws -> Report {
        var report = Report()
        for requirement in requirements {
            let rows = try database.query("SELECT name FROM pragma_table_info(?)", [.text(requirement.table)])
            let present = Set(rows.compactMap { $0.values.first?.string })
            if present.isEmpty {
                report.missingTables.append(requirement.table)
                continue
            }
            let missing = requirement.columns.filter { !present.contains($0) }
            if !missing.isEmpty {
                report.missingColumns[requirement.table] = missing
            }
        }
        return report
    }
}
