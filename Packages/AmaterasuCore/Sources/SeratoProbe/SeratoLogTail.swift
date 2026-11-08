import Foundation

/// A `[Library]` line from Serato's own log, e.g.
/// `I20261106 20:00:04.233579 85622656 :0] [Library] Updating entry with id 3202`.
struct SeratoLogEvent {
    enum Kind: Equatable {
        case addEntry(sessionID: Int64)
        case updateEntry(entryID: Int64)
        case other
    }

    let time: Date
    let kind: Kind
    let message: String
}

/// Follows Serato's current log file (`DJ.INFO` symlink) and returns new `[Library]` events.
/// Serato timestamps each line to the microsecond, which gives an independent clock for
/// measuring how long a change takes to show up in the database.
@MainActor
final class SeratoLogTail {
    private let directory: URL
    private var file: URL?
    private var offset: UInt64 = 0
    private var pending = Data()
    private let secondsFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd HH:mm:ss"
        return formatter
    }()

    init(directory: URL) {
        self.directory = directory
    }

    /// New events since the last call. The first call starts at the end of the current file;
    /// when Serato starts a new log file, that file is read from the beginning.
    func poll() -> [SeratoLogEvent] {
        guard let current = currentLogFile() else { return [] }
        if current != file {
            let isFirstFile = file == nil
            file = current
            offset = isFirstFile ? fileSize(current) : 0
            pending = Data()
        }

        let size = fileSize(current)
        if size < offset {
            offset = 0
            pending = Data()
        }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: current) else { return [] }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd() else { return [] }
        offset += UInt64(data.count)
        pending.append(data)

        var events: [SeratoLogEvent] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...newline)
            if let event = parse(line) { events.append(event) }
        }
        return events
    }

    private func currentLogFile() -> URL? {
        let link = directory.appending(path: "DJ.INFO").path
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else { return nil }
        return target.hasPrefix("/") ? URL(fileURLWithPath: target) : directory.appending(path: target)
    }

    private func fileSize(_ url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func parse(_ line: String) -> SeratoLogEvent? {
        guard let marker = line.range(of: "] [Library] ") else { return nil }
        let message = String(line[marker.upperBound...])

        // "I20261106 20:00:04.233579 …": severity letter, date, time with microseconds.
        let stamp = line.dropFirst()
        guard stamp.count >= 24,
              let whole = secondsFormatter.date(from: String(stamp.prefix(17))),
              let fraction = Double("0" + stamp.dropFirst(17).prefix(7))
        else { return nil }
        let time = whole.addingTimeInterval(fraction)

        let kind: SeratoLogEvent.Kind
        if let id = trailingID(message, after: "Adding entry to history session with id ") {
            kind = .addEntry(sessionID: id)
        } else if let id = trailingID(message, after: "Updating entry with id ") {
            kind = .updateEntry(entryID: id)
        } else {
            kind = .other
        }
        return SeratoLogEvent(time: time, kind: kind, message: message)
    }

    private func trailingID(_ message: String, after prefix: String) -> Int64? {
        guard message.hasPrefix(prefix) else { return nil }
        return Int64(message.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces))
    }
}
