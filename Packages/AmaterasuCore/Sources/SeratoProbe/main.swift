import Domain
import Foundation
import SeratoDatabase

let usage = """
serato-probe: Phase 0 tool that reads Serato DJ Pro 4's history database (never writes to it).

USAGE
  serato-probe schema   [--db PATH]
  serato-probe sessions [--db PATH] [--limit N]
  serato-probe dump     [--db PATH] [--session ID] [--full]
  serato-probe suggest  --key KEY [--bpm BPM] [--limit N] [--db PATH]
  serato-probe analyze  [--session ID] [--db PATH]
  serato-probe watch    [--db PATH] [--interval SECONDS] [--log FILE] [--serato-logs DIR]
                        [--no-process-check]

schema, sessions and dump read the live database (read-only) while Serato runs,
otherwise a temporary copy. watch reads only the live database and waits for Serato.
In watch mode, type a note and press Enter the moment you act in Serato to record
a timestamped MARK (e.g. "play d1").

Default database: \(SeratoLibrary.databaseURL.path)
"""

struct UsageError: Error, CustomStringConvertible {
    let description: String
}

struct Options {
    var command: String
    var database = SeratoLibrary.databaseURL
    var sessionID: Int64?
    var limit = 10
    var full = false
    var interval: TimeInterval = 0.25
    var logFile: URL?
    var seratoLogs = SeratoLibrary.logsDirectory
    var requireSerato = true
    var key: String?
    var bpm: Double?

    init(arguments: [String]) throws {
        var remaining = arguments[...]
        guard let command = remaining.popFirst() else { throw UsageError(description: "missing command") }
        self.command = command

        func value(for flag: String) throws -> String {
            guard let value = remaining.popFirst() else { throw UsageError(description: "\(flag) needs a value") }
            return value
        }
        func path(for flag: String) throws -> URL {
            URL(fileURLWithPath: (try value(for: flag) as NSString).expandingTildeInPath)
        }

        while let argument = remaining.popFirst() {
            switch argument {
            case "--db":
                database = try path(for: argument)
            case "--session":
                guard let id = Int64(try value(for: argument)) else { throw UsageError(description: "--session needs an integer") }
                sessionID = id
            case "--limit":
                guard let n = Int(try value(for: argument)), n > 0 else { throw UsageError(description: "--limit needs a positive integer") }
                limit = n
            case "--full":
                full = true
            case "--interval":
                guard let seconds = Double(try value(for: argument)), seconds >= 0.05 else {
                    throw UsageError(description: "--interval needs a number ≥ 0.05")
                }
                interval = seconds
            case "--log":
                logFile = try path(for: argument)
            case "--serato-logs":
                seratoLogs = try path(for: argument)
            case "--no-process-check":
                requireSerato = false
            case "--key":
                key = try value(for: argument)
            case "--bpm":
                guard let value = Double(try value(for: argument)) else { throw UsageError(description: "--bpm needs a number") }
                bpm = value
            default:
                throw UsageError(description: "unknown option \(argument)")
            }
        }
    }
}

/// The live database read-only when Serato is running, otherwise a temporary copy.
@MainActor
func openForInspection(_ url: URL, out: Output) throws -> SQLiteDatabase {
    if let live = try? SeratoLibrary.openLive(url), (try? live.dataVersion()) != nil {
        out.line("source: live database, read-only (\(url.path))")
        return live
    }
    let snapshot = try SeratoLibrary.openSnapshot(of: url)
    out.line("source: temporary copy of \(url.path) (live database not available)")
    return snapshot
}

@MainActor
func runSchema(_ options: Options, out: Output) throws {
    let database = try openForInspection(options.database, out: out)
    let journalMode = try database.query("PRAGMA journal_mode").first?.values.first?.string ?? "?"
    out.line("journal_mode: \(journalMode)")
    let report = try SeratoSchema.check(database)
    for requirement in SeratoSchema.required {
        if report.missingTables.contains(requirement.table) {
            out.line("✗ \(requirement.table): table missing")
        } else if let missing = report.missingColumns[requirement.table] {
            out.line("✗ \(requirement.table): missing \(missing.joined(separator: ", "))")
        } else {
            out.line("✓ \(requirement.table): \(requirement.columns.joined(separator: ", "))")
        }
    }
    if !report.missingTables.contains("history_entry"),
       let version = try database.query("SELECT app_version FROM history_entry ORDER BY id DESC LIMIT 1").first?.values.first {
        out.line("latest entry written by Serato \(version)")
    }
    out.line(report.isCompatible ? "result: compatible" : "result: NOT compatible")
}

@MainActor
func runSessions(_ options: Options, out: Output) throws {
    let database = try openForInspection(options.database, out: out)
    for session in try HistoryQueries.sessions(database, limit: options.limit) {
        let count = try HistoryQueries.entryCount(database, sessionID: session.id)
        out.line("\(Fmt.session(session))  entries=\(count)")
    }
}

@MainActor
func runDump(_ options: Options, out: Output) throws {
    let database = try openForInspection(options.database, out: out)
    let session: HistorySession?
    if let id = options.sessionID {
        session = try HistoryQueries.session(database, id: id)
    } else {
        session = try HistoryQueries.sessions(database, limit: 1).first
    }
    guard let session else {
        out.line("no such session")
        return
    }
    let rows = try HistoryQueries.entryRows(database, sessionID: session.id)
    let locations = options.full ? try HistoryQueries.locationPaths(database) : [:]
    out.line("\(Fmt.session(session))  entries=\(rows.count)")
    for row in rows {
        out.line(Fmt.entry(row))
        guard options.full else { continue }
        out.line("    \(Fmt.entryDetails(row))")
        if let path = HistoryQueries.filePath(of: row, locations: locations) {
            let exists = FileManager.default.fileExists(atPath: path)
            out.line("    path: \(path) \(exists ? "✓ exists" : "✗ not found")")
        }
    }
    if !rows.isEmpty { out.line("decks: \(Fmt.deckSummary(rows))") }
}

/// The session analysis the app shows, as text: transitions, tempo and summary.
@MainActor
func runAnalyze(_ options: Options, out: Output) throws {
    let database = try openForInspection(options.database, out: out)
    guard let session = try options.sessionID.map({ try HistoryQueries.session(database, id: $0) }) ?? HistoryQueries.sessions(database, limit: 1).first else {
        out.line("no such session")
        return
    }
    let tracks = SessionHistory.playedTracks(from: try HistoryQueries.entryRowsWithLibraryValues(database, sessionID: session.id))
    let analysis = SetAnalysis(tracks: tracks, now: session.isOpen ? Date() : nil)
    out.line("\(Fmt.session(session))")
    let labels: [SetTransition.Kind: String] = [.harmonic: "Harmonic", .energyBoost: "Energy boost", .keyJump: "Key jump", .unknownKey: "Unknown key"]
    for (index, track) in tracks.enumerated() {
        let time = Tracklist.timestamp(track.startedAt.timeIntervalSince(tracks[0].startedAt))
        let bpm = track.bpm.map { String(format: "%.1f→%.0f", $0, analysis.setTempo($0)) } ?? "—"
        var move = "Opener"
        if index > 0 {
            let transition = analysis.transitions[index - 1]
            let change = transition.tempoChangePercent.map { String(format: "%+.1f%%", $0) } ?? ""
            let detail = transition.kind == .harmonic || transition.relation == .semitoneUp ? transition.relation.map { "(\($0.label))" } ?? "" : ""
            move = "\(labels[transition.kind] ?? "")\(detail) \(change)"
        }
        out.line("  \(time)  \(track.key?.camelot ?? "—")\t\(bpm)\t\(move)\t\(track.displayName)")
    }
    let share = analysis.harmonicShare.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
    let range = analysis.tempoRange.map { String(format: "%.0f–%.0f", $0.lowerBound, $0.upperBound) } ?? "—"
    let jump = analysis.biggestTempoJump.map { String(format: "%+.1f%% (into #%d)", $0.percent, $0.trackIndex + 1) } ?? "—"
    out.line("summary: \(Tracklist.timestamp(analysis.duration)) · \(tracks.count) tracks · avg \(Tracklist.timestamp(analysis.averageTrackDuration ?? 0)) per track · tempo \(range) · harmonic \(share) (jumps \(analysis.count(.keyJump)), boosts \(analysis.count(.energyBoost))) · biggest jump \(jump)")
}

/// What the panel would suggest after a track in `--key` at `--bpm`, from the library's local tracks.
@MainActor
func runSuggest(_ options: Options, out: Output) throws {
    guard let text = options.key, let key = KeyParser.parse(text) else {
        throw UsageError(description: "--key needs a key such as 8A, Am or 1m")
    }
    let database = try openForInspection(options.database, out: out)
    let thresholds = BPMThresholds()
    let keys = HarmonicRecommender.recommendations(for: key).map(\.key)
    let range = options.bpm.map { ($0 / (1 + thresholds.compatible / 100))...($0 / (1 - thresholds.compatible / 100)) }
    let candidates = try LibraryQueries.candidates(database, keys: keys, bpmRange: range)
    out.line("main: \(key.camelot) \(options.bpm.map { String($0) } ?? "no BPM")  candidates: \(candidates.count)")
    for suggestion in TrackSuggester.suggest(from: candidates, mainKey: key, mainBPM: options.bpm, thresholds: thresholds, limit: options.limit) {
        let track = suggestion.track
        let pitch = suggestion.bpm.map { String(format: "%+.1f%%", $0.pitchPercent) + ($0.ratio == .normal ? "" : $0.ratio == .double ? " ×2" : " ×½") } ?? ""
        out.line("  \(track.key?.camelot ?? "—")\t\(track.bpm.map { String(format: "%.1f", $0) } ?? "—")\t\(pitch)\t\(suggestion.relation.label)\t\(track.artist ?? "") - \(track.title ?? "")  (played \(track.playCount)×)")
    }
}

@MainActor
func runWatch(_ options: Options, out: Output) {
    let watcher = Watcher(
        databaseURL: options.database,
        seratoLogs: options.seratoLogs,
        requireSerato: options.requireSerato,
        out: out
    )
    watcher.start(interval: options.interval)
    Thread.detachNewThread {
        while let line = readLine() {
            Task { @MainActor in watcher.mark(line) }
        }
    }
    RunLoop.main.run()
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty || ["-h", "--help", "help"].contains(arguments[0]) {
    print(usage)
    exit(0)
}

do {
    let options = try Options(arguments: arguments)
    let out = try Output(logFile: options.logFile)
    switch options.command {
    case "schema": try runSchema(options, out: out)
    case "sessions": try runSessions(options, out: out)
    case "dump": try runDump(options, out: out)
    case "suggest": try runSuggest(options, out: out)
    case "analyze": try runAnalyze(options, out: out)
    case "watch": runWatch(options, out: out)
    default: throw UsageError(description: "unknown command \(options.command)")
    }
} catch let error as UsageError {
    FileHandle.standardError.write(Data("error: \(error)\n\n\(usage)\n".utf8))
    exit(64)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
