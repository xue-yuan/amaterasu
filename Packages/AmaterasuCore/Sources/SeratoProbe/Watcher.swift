import AppKit
import Foundation
import SeratoDatabase

/// `serato-probe watch`: follows the live database and prints every change to the current history
/// session with timestamps, alongside Serato's own log lines and the user's MARKs.
///
/// It never keeps a connection open: it watches the `-wal` / database file signatures and only opens a
/// read-only connection for the duration of one query when they change. A connection that is open when
/// Serato quits stops Serato from checkpointing and removing its WAL (observed in Phase 0).
@MainActor
final class Watcher {
    private let databaseURL: URL
    private let out: Output
    private let logTail: SeratoLogTail
    private let requireSerato: Bool
    private var seratoRunning = false
    private var lastSignature: DatabaseSignature?
    private var schemaChecked = false
    private var session: HistorySession?
    private var entries: [Int64: SQLRow] = [:]
    private var lastProblem: String?
    private var matcher = LatencyMatcher()
    private var markCount = 0

    /// `requireSerato: false` reads the database as soon as its `-wal` exists (for simulations).
    init(databaseURL: URL, seratoLogs: URL, requireSerato: Bool, out: Output) {
        self.databaseURL = databaseURL
        self.requireSerato = requireSerato
        self.out = out
        self.logTail = SeratoLogTail(directory: seratoLogs)
    }

    func start(interval: TimeInterval) {
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: SeratoLibrary.bundleIdentifier).isEmpty
        seratoRunning = running || !requireSerato
        out.event("INFO", "database \(databaseURL.path)")
        out.event("INFO", "Serato is \(running ? "running" : "not running"); checking for changes every \(interval)s"
            + (requireSerato ? "" : " (process check disabled)"))
        out.event("INFO", "type a note and press Enter the moment you act in Serato to record a MARK")
        observeWorkspace()
        _ = logTail.poll() // skip what is already in the log
        tick()
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
    }

    func mark(_ note: String) {
        markCount += 1
        let note = note.trimmingCharacters(in: .whitespaces)
        out.event("MARK", note.isEmpty ? "#\(markCount)" : "#\(markCount) \(note)")
    }

    private func tick() {
        for event in logTail.poll() { report(event) }
        guard seratoRunning else { return }
        guard let signature = DatabaseSignature(database: databaseURL) else {
            noteProblem("no \(databaseURL.lastPathComponent)-wal (Serato starting or quitting?)")
            return
        }
        guard signature != lastSignature else { return }

        let started = Date()
        do {
            let (latest, rows) = try readCurrentSession()
            let queryTime = Date().timeIntervalSince(started)
            let isBaseline = lastSignature == nil
            lastSignature = signature
            lastProblem = nil
            apply(latest, rows, baseline: isBaseline, walSize: signature.walSize, queryTime: queryTime, seenAt: started)
        } catch {
            noteProblem("\(error)") // lastSignature unchanged: retried on the next tick
        }
    }

    /// Opens a read-only connection, reads the latest session in one short transaction, and closes it.
    private func readCurrentSession() throws -> (HistorySession?, [SQLRow]) {
        let database = try SeratoLibrary.openLive(databaseURL)
        if !schemaChecked {
            let report = try SeratoSchema.check(database)
            schemaChecked = true
            if report.isCompatible {
                out.event("INFO", "schema compatible")
            } else {
                out.event("WARN", "schema mismatch: missing tables \(report.missingTables), columns \(report.missingColumns)")
            }
        }
        return try database.readTransaction { () throws -> (HistorySession?, [SQLRow]) in
            guard let latest = try HistoryQueries.sessions(database, limit: 1).first else { return (nil, []) }
            return (latest, try HistoryQueries.entryRows(database, sessionID: latest.id))
        }
    }

    private func apply(
        _ latest: HistorySession?,
        _ rows: [SQLRow],
        baseline: Bool,
        walSize: Int64,
        queryTime: TimeInterval,
        seenAt: Date
    ) {
        var current: [Int64: SQLRow] = [:]
        for row in rows {
            if let id = row["id"].int64 { current[id] = row }
        }
        let files = "wal=\(Fmt.bytes(walSize)) query=\(Int((queryTime * 1000).rounded()))ms"

        if baseline {
            session = latest
            entries = current
            out.event("BASE", "\(files) \(Fmt.session(latest)) entries=\(rows.count)", at: seenAt)
            if !rows.isEmpty { out.event("DECKS", Fmt.deckSummary(rows), at: seenAt) }
            return
        }

        var changes: [(tag: String, text: String)] = []
        if latest?.id != session?.id {
            changes.append(("SESSION", "new \(Fmt.session(latest))"))
            entries = [:]
        } else if latest != session {
            changes.append(("SESSION", "changed \(Fmt.session(latest))"))
        }
        session = latest

        for row in rows {
            guard let id = row["id"].int64 else { continue }
            if let old = entries[id] {
                let diff = Fmt.diff(old, row)
                guard !diff.isEmpty else { continue }
                var text = "#\(id) d\(row["deck"].string ?? "?") " + diff.joined(separator: ", ")
                if let end = row["end_time"].int64, end >= 0, old["end_time"] != row["end_time"] {
                    text += "  [seen \(Fmt.seconds(seenAt.timeIntervalSince1970 - Double(end))) after end_time]"
                }
                if let lag = matcher.databaseUpdate(id: id, at: seenAt) {
                    text += "  [db−log \(Fmt.seconds(lag))]"
                }
                changes.append(("UPD", text))
            } else {
                var text = Fmt.entry(row)
                if let start = row["start_time"].int64 {
                    text += "  [seen \(Fmt.seconds(seenAt.timeIntervalSince1970 - Double(start))) after start_time]"
                }
                if let lag = matcher.databaseAdd(id: id, at: seenAt) {
                    text += "  [db−log \(Fmt.seconds(lag))]"
                }
                changes.append(("NEW", text))
            }
        }
        for id in entries.keys.sorted() where current[id] == nil {
            changes.append(("DEL", "#\(id)"))
        }
        entries = current

        out.event("CHANGE", files + (changes.isEmpty ? " (no history change)" : ""), at: seenAt)
        for change in changes { out.event(change.tag, change.text, at: seenAt) }
        if !changes.isEmpty { out.event("DECKS", Fmt.deckSummary(rows), at: seenAt) }
    }

    private func report(_ event: SeratoLogEvent) {
        var text = "@\(Fmt.clock(event.time)) \(event.message)"
        switch event.kind {
        case .addEntry:
            if let match = matcher.logAdd(at: event.time) {
                text += "  [#\(match.id) db−log \(Fmt.seconds(match.lag))]"
            }
        case .updateEntry(let id):
            if let lag = matcher.logUpdate(id: id, at: event.time) {
                text += "  [db−log \(Fmt.seconds(lag))]"
            }
        case .other:
            break
        }
        out.event("SLOG", text)
    }

    private func noteProblem(_ problem: String) {
        guard problem != lastProblem else { return }
        out.event("WAIT", "\(problem); retrying")
        lastProblem = problem
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, Bool)] = [
            (NSWorkspace.didLaunchApplicationNotification, true),
            (NSWorkspace.didTerminateApplicationNotification, false),
        ]
        for (name, launched) in events {
            center.addObserver(forName: name, object: nil, queue: .main) { notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == SeratoLibrary.bundleIdentifier else { return }
                MainActor.assumeIsolated { self.seratoChanged(launched: launched) }
            }
        }
    }

    private func seratoChanged(launched: Bool) {
        seratoRunning = launched || !requireSerato
        out.event("SERATO", launched ? "launched" : "quit")
        lastSignature = nil
        schemaChecked = false
        guard !launched else { return }
        // Serato normally checkpoints and removes its WAL on quit; check that we did not prevent it.
        let wal = SeratoLibrary.walURL(for: databaseURL)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                let exists = FileManager.default.fileExists(atPath: wal.path)
                self.out.event("INFO", "2s after quit: -wal \(exists ? "still exists" : "removed")")
            }
        }
    }
}

/// Pairs database changes with Serato's log lines, whichever is seen first.
/// Adds are paired in order (the log line has no entry id); updates are paired per entry id.
struct LatencyMatcher {
    private var databaseAdds: [(id: Int64, at: Date)] = []
    private var logAdds: [Date] = []
    private var databaseUpdates: [Int64: [Date]] = [:]
    private var logUpdates: [Int64: [Date]] = [:]

    /// Seconds between Serato's log line and our seeing the new row, if the log line came first.
    mutating func databaseAdd(id: Int64, at seen: Date) -> TimeInterval? {
        guard !logAdds.isEmpty else {
            databaseAdds.append((id, seen))
            return nil
        }
        return seen.timeIntervalSince(logAdds.removeFirst())
    }

    mutating func logAdd(at logged: Date) -> (id: Int64, lag: TimeInterval)? {
        guard !databaseAdds.isEmpty else {
            logAdds.append(logged)
            return nil
        }
        let add = databaseAdds.removeFirst()
        return (add.id, add.at.timeIntervalSince(logged))
    }

    mutating func databaseUpdate(id: Int64, at seen: Date) -> TimeInterval? {
        guard let logged = logUpdates[id]?.first else {
            databaseUpdates[id, default: []].append(seen)
            return nil
        }
        logUpdates[id]?.removeFirst()
        return seen.timeIntervalSince(logged)
    }

    mutating func logUpdate(id: Int64, at logged: Date) -> TimeInterval? {
        guard let seen = databaseUpdates[id]?.first else {
            logUpdates[id, default: []].append(logged)
            return nil
        }
        databaseUpdates[id]?.removeFirst()
        return seen.timeIntervalSince(logged)
    }
}
