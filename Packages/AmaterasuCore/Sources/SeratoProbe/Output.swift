import Foundation
import SeratoDatabase

/// Writes lines to stdout and, optionally, appends them to a log file.
@MainActor
final class Output {
    private let file: FileHandle?

    init(logFile: URL?) throws {
        guard let logFile else {
            file = nil
            return
        }
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logFile)
        try handle.seekToEnd()
        file = handle
    }

    func line(_ text: String) {
        let data = Data((text + "\n").utf8)
        FileHandle.standardOutput.write(data)
        try? file?.write(contentsOf: data)
    }

    /// A timestamped event line, e.g. `21:03:12.345  NEW     #3226 d1 …`.
    func event(_ tag: String, _ text: String, at date: Date = Date()) {
        line("\(Fmt.clock(date))  \(tag.padding(toLength: 7, withPad: " ", startingAt: 0)) \(text)")
    }
}

@MainActor
enum Fmt {
    private static let clockFormatter = formatter("HH:mm:ss.SSS")
    private static let secondsFormatter = formatter("HH:mm:ss")
    private static let dateTimeFormatter = formatter("yyyy-MM-dd HH:mm:ss")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }

    static func dateTime(_ date: Date) -> String { dateTimeFormatter.string(from: date) }

    /// A Unix-seconds column as local `HH:mm:ss`; negative values and NULL are shown as-is.
    static func unixTime(_ value: SQLValue) -> String {
        guard let seconds = value.int64, seconds >= 0 else { return value.description }
        return secondsFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    static func bytes(_ count: Int64?) -> String {
        guard let count else { return "—" }
        return ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func seconds(_ interval: TimeInterval) -> String { String(format: "%+.2fs", interval) }

    static func session(_ session: HistorySession?) -> String {
        guard let session else { return "session —" }
        let end = session.endTime.map(dateTime) ?? "(open)"
        return "session #\(session.id) \"\(session.name)\" \(dateTime(session.startTime)) → \(end)"
    }

    /// One-line summary of a history entry.
    static func entry(_ row: SQLRow) -> String {
        let bpm = row["bpm"].double.map { String(format: "%.2f", $0) } ?? "—"
        let key = row["key"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "—"
        return "#\(row["id"]) d\(row["deck"].string ?? "?") played=\(row["played"]) "
            + "\(unixTime(row["start_time"]))→\(unixTime(row["end_time"]))  "
            + "bpm=\(bpm) key=\(key)(\(row["key_value"]))  "
            + "\"\(row["name"].string ?? "")\" — \(row["artist"].string ?? "")"
    }

    /// Columns not shown by `entry(_:)`, skipping empty values and the derived `*_norm` columns.
    static func entryDetails(_ row: SQLRow) -> String {
        let shown: Set<String> = ["id", "deck", "played", "start_time", "end_time", "bpm", "key", "key_value", "name", "artist"]
        return zip(row.columns, row.values).compactMap { column, value -> String? in
            guard !shown.contains(column), !column.hasSuffix("_norm") else { return nil }
            switch value {
            case .null: return nil
            case .text(let text) where text.isEmpty: return nil
            default: return "\(column)=\(value)"
            }
        }.joined(separator: " ")
    }

    /// The latest entry on each deck, e.g. `[1] ▶ played "A" | [2] ■ loaded "B"`.
    static func deckSummary(_ rows: [SQLRow]) -> String {
        var latest: [String: SQLRow] = [:]
        for row in rows { latest[row["deck"].string ?? "?"] = row } // rows are ordered by id
        return latest.keys.sorted().map { deck in
            let row = latest[deck]!
            let state: String
            if row["end_time"].int64 != -1 {
                state = "⏏ ended"
            } else if row["played"].int64 == 1 {
                state = "▶ played"
            } else {
                state = "■ loaded"
            }
            return "[\(deck)] \(state) \"\(row["name"].string ?? "")\""
        }.joined(separator: "  |  ")
    }

    /// `column: old → new` for every column whose value changed.
    static func diff(_ old: SQLRow, _ new: SQLRow) -> [String] {
        new.columns.compactMap { column in
            let before = old[column]
            let after = new[column]
            guard before != after else { return nil }
            return "\(column): \(display(column, before)) → \(display(column, after))"
        }
    }

    private static func display(_ column: String, _ value: SQLValue) -> String {
        guard column.hasSuffix("_time"), let seconds = value.int64, seconds >= 0 else { return value.description }
        return "\(seconds) (\(unixTime(value)))"
    }
}
