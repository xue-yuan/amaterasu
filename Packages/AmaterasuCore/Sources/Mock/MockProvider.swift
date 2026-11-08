import Domain
import Foundation

/// Fake decks for development and previews.
///
/// Every `interval` the deck that is not main gets a new track, which starts playing a few seconds later,
/// so the panel's auto-expand and main-deck logic can be exercised without Serato. `advance()` does the
/// same on demand.
@MainActor
public final class MockProvider: DeckStateProvider {
    public let updates: AsyncStream<[DeckState]>
    private let continuation: AsyncStream<[DeckState]>.Continuation
    private let deckCount: Int
    private let interval: Duration
    private let playDelay: Duration
    private var decks: [DeckState] = []
    private var nextTrack = 0
    private var loop: Task<Void, Never>?

    public init(deckCount: Int = 2, interval: Duration = .seconds(30), playDelay: Duration = .seconds(4)) {
        (updates, continuation) = AsyncStream.makeStream(of: [DeckState].self, bufferingPolicy: .bufferingNewest(1))
        self.deckCount = min(max(deckCount, 1), 4)
        self.interval = interval
        self.playDelay = playDelay
    }

    public func start() async throws {
        guard loop == nil else { return }
        let now = Date()
        decks = (1...deckCount).map { id in
            // Deck 1 has been playing for a while; the others are loaded and waiting.
            let loadedAt = now.addingTimeInterval(TimeInterval(id - deckCount - 1) * 60)
            return makeDeck(id, loadedAt: loadedAt, startedAt: id == 1 ? loadedAt.addingTimeInterval(5) : nil)
        }
        continuation.yield(decks)

        let interval = self.interval
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self?.advance()
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Loads the next fake track onto a deck that is not main, then starts it after `playDelay`.
    public func advance() {
        guard !decks.isEmpty else { return }
        let main = MainDeck.select(from: decks)
        let target = decks.first { $0.id != main }?.id ?? decks[0].id
        let loadedAt = Date()
        replace(makeDeck(target, loadedAt: loadedAt, startedAt: nil))

        let playDelay = self.playDelay
        Task { [weak self] in
            try? await Task.sleep(for: playDelay)
            self?.startPlaying(deck: target, loadedAt: loadedAt)
        }
    }

    private func startPlaying(deck id: Int, loadedAt: Date) {
        guard var deck = decks.first(where: { $0.id == id }), deck.loadedAt == loadedAt else { return }
        deck.hasStartedPlaying = true
        deck.playStartedAt = Date()
        replace(deck)
    }

    private func replace(_ deck: DeckState) {
        decks.removeAll { $0.id == deck.id }
        decks.append(deck)
        decks.sort { $0.id < $1.id }
        continuation.yield(decks)
    }

    private func makeDeck(_ id: Int, loadedAt: Date, startedAt: Date?) -> DeckState {
        let track = Self.tracks[nextTrack % Self.tracks.count]
        nextTrack += 1
        return DeckState(
            id: id,
            title: track.title,
            artist: track.artist,
            bpm: track.bpm,
            key: track.key,
            hasStartedPlaying: startedAt != nil,
            loadedAt: loadedAt,
            playStartedAt: startedAt
        )
    }

    private struct Track {
        let title: String
        let artist: String
        let bpm: Double?
        let key: MusicalKey?

        init(_ title: String, _ artist: String, _ bpm: Double?, _ camelot: (Int, Bool)?) {
            self.title = title
            self.artist = artist
            self.bpm = bpm
            self.key = camelot.flatMap { MusicalKey(number: $0.0, isMinor: $0.1) }
        }
    }

    /// Invented tracks, including an unanalysed one and a very long title to exercise the layout.
    private static let tracks: [Track] = [
        Track("Midnight Circuit", "Neon Harbor", 124.0, (8, true)),
        Track("Paper Lanterns", "Kaito & The Tide", 126.0, (9, true)),
        Track("Low Orbit", "Sora Vale", 122.5, (8, false)),
        Track("An Extremely Long Track Title That Should Truncate Nicely (Extended Club Mix)", "Glass Avenue", 128.0, (10, true)),
        Track("Rooftop Static", "Amber Lane", 93.0, (5, true)),
        Track("Slow Burn City", "The Fold", 70.0, (4, true)),
        Track("Unanalysed Demo", "Unknown Artist", nil, nil),
        Track("Hyperlight", "Juno Park", 140.0, (11, false)),
        Track("Velvet Signal", "Orchid Unit", 100.0, (7, true)),
        Track("Echo Market", "Rae Monroe", 86.5, (1, true)),
        Track("Northbound", "Static Gardens", 118.0, (12, false)),
    ]
}

extension MockProvider {
    /// An invented library for demo-mode suggestions: three tracks in every key at assorted tempos.
    public static let library: [LibraryTrack] = {
        let adjectives = ["Neon", "Velvet", "Static", "Paper", "Lunar", "Golden", "Hollow", "Crystal", "Midnight", "Electric", "Silent", "Wild"]
        let nouns = ["Harbor", "Signal", "Garden", "Avenue", "Orbit", "Engine", "Mirror", "Desert", "Cascade", "Parade", "Circuit", "Bloom"]
        let artists = ["Kaito Vale", "Rae Monroe", "Juno Park", "The Fold", "Orchid Unit", "Amber Lane", "Sora Hill", "Glass Avenue"]
        let tempos: [Double] = [62, 70, 86, 93, 100, 118, 122, 124, 126, 128, 140]
        var tracks: [LibraryTrack] = []
        for (keyIndex, key) in MusicalKey.all.enumerated() {
            for variant in 0..<3 {
                let n = keyIndex * 3 + variant
                tracks.append(LibraryTrack(
                    id: Int64(900_000 + n),
                    title: "\(adjectives[n % 12]) \(nouns[(n * 5 + variant) % 12])",
                    artist: artists[n % artists.count],
                    bpm: tempos[(n * 7) % tempos.count],
                    key: key,
                    playCount: n % 4
                ))
            }
        }
        return tracks
    }()
}
