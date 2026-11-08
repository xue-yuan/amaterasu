import Domain
import Foundation

/// Deck states from Serato DJ Pro 4's history database.
///
/// While Serato runs, it checks the database files' signature every `interval`; only when they change does
/// it open a read-only connection, read the newest session and its entries in one short transaction, and
/// close it again. No connection is kept between reads: one that is open when Serato quits
/// stops Serato from cleaning up its WAL (docs/serato-findings.md §3.5).
@MainActor
public final class SeratoDatabaseProvider: DeckStateProvider {
    public let updates: AsyncStream<[DeckState]>
    private let continuation: AsyncStream<[DeckState]>.Continuation
    private let database: URL
    private let interval: Duration
    private var loop: Task<Void, Never>?
    private var tracker = DeckTracker()
    private var lastSignature: DatabaseSignature?
    /// The decks most recently sent to `updates`.
    private(set) var lastPublished: [DeckState]?
    private var retryAfter: Date?

    /// Why the most recent read failed, if it did; cleared by the next successful read.
    public private(set) var lastError: (any Error)?

    /// The newest session's tracklist and loaded tracks. Kept after Serato quits, so the tracklist can still
    /// be copied; replaced when a newer session is read.
    public private(set) var session: SessionSummary?
    public var onSessionChange: ((SessionSummary?) -> Void)?

    /// Set by the app from NSWorkspace (kept out of this module). The database is only read while Serato
    /// runs; when it stops, the decks are cleared.
    public var isSeratoRunning = false {
        didSet {
            guard isSeratoRunning != oldValue else { return }
            lastSignature = nil
            retryAfter = nil
            if isSeratoRunning {
                poll()
            } else {
                tracker = DeckTracker()
                publish([])
            }
        }
    }

    public init(database: URL = SeratoLibrary.databaseURL, interval: Duration = .milliseconds(250)) {
        (updates, continuation) = AsyncStream.makeStream(of: [DeckState].self, bufferingPolicy: .bufferingNewest(1))
        self.database = database
        self.interval = interval
    }

    public func start() async throws {
        guard loop == nil else { return }
        if !isSeratoRunning { publish([]) }
        let interval = self.interval
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let provider = self else { return }
                provider.poll()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Re-reads the database if Serato wrote to it since the last read.
    func poll(now: Date = Date()) {
        guard isSeratoRunning else { return }
        if let retryAfter, now < retryAfter { return }
        guard let signature = DatabaseSignature(database: database), signature != lastSignature else { return }
        do {
            let (session, entries) = try read()
            lastSignature = signature
            lastError = nil
            retryAfter = nil
            publish(tracker.update(session: session, entries: entries, now: now))
            let summary = session.map { SessionHistory.summary(of: $0, entries: entries) }
            if summary != self.session {
                self.session = summary
                onSessionChange?(summary)
            }
        } catch {
            // Keep showing the last decks; try again shortly rather than on every tick.
            lastError = error
            retryAfter = now.addingTimeInterval(2)
        }
    }

    /// The newest session (open or ended) and all of its entries.
    private func read() throws -> (HistorySession?, [SQLRow]) {
        let connection = try SeratoLibrary.openLive(database) // closed when this function returns
        return try connection.readTransaction { () throws -> (HistorySession?, [SQLRow]) in
            guard let session = try HistoryQueries.sessions(connection, limit: 1).first else { return (nil, []) }
            return (session, try HistoryQueries.entryRowsWithLibraryValues(connection, sessionID: session.id))
        }
    }

    private func publish(_ decks: [DeckState]) {
        guard decks != lastPublished else { return }
        lastPublished = decks
        continuation.yield(decks)
    }
}
