import Foundation

/// What the panel knows about one deck that has a track loaded.
public struct DeckState: Identifiable, Equatable, Sendable {
    /// Deck number, 1...4.
    public let id: Int
    public var title: String?
    public var artist: String?
    public var bpm: Double?
    public var key: MusicalKey?
    /// The track has started playing at least once. Serato does not record pauses, so "playing right now"
    /// cannot be known (see docs/serato-findings.md).
    public var hasStartedPlaying: Bool
    public var loadedAt: Date?
    /// When playback started, if known; used to pick the main deck.
    public var playStartedAt: Date?
    /// When this track last started playing earlier in tonight's session, if it did (a repeat warning).
    public var playedEarlierAt: Date?

    public init(
        id: Int,
        title: String? = nil,
        artist: String? = nil,
        bpm: Double? = nil,
        key: MusicalKey? = nil,
        hasStartedPlaying: Bool = false,
        loadedAt: Date? = nil,
        playStartedAt: Date? = nil,
        playedEarlierAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.bpm = bpm
        self.key = key
        self.hasStartedPlaying = hasStartedPlaying
        self.loadedAt = loadedAt
        self.playStartedAt = playStartedAt
        self.playedEarlierAt = playedEarlierAt
    }
}

/// A source of deck state. The UI does not know where the data comes from.
@MainActor
public protocol DeckStateProvider: AnyObject {
    /// Each value is every deck that currently has a track loaded, ordered by deck number.
    var updates: AsyncStream<[DeckState]> { get }
    func start() async throws
    func stop()
}
