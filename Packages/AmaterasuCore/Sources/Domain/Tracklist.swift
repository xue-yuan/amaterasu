import Foundation

/// A track that played in a session.
public struct PlayedTrack: Equatable, Sendable {
    public let title: String?
    public let artist: String?
    public let deck: Int
    public let startedAt: Date
    /// When it left the deck; nil while it is still on one.
    public let endedAt: Date?
    /// Serato's analysis (the library's current value when there is one).
    public let bpm: Double?
    public let key: MusicalKey?
    /// The track's own length, if known.
    public let length: TimeInterval?

    public init(
        title: String?, artist: String?, deck: Int, startedAt: Date,
        endedAt: Date? = nil, bpm: Double? = nil, key: MusicalKey? = nil, length: TimeInterval? = nil
    ) {
        self.title = title
        self.artist = artist
        self.deck = deck
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.bpm = bpm
        self.key = key
        self.length = length
    }

    /// `Artist - Title`, or whichever of the two is known.
    public var displayName: String {
        displayName(unknown: "(Unknown track)")
    }

    /// `Artist - Title`, or `unknown` when neither is known.
    public func displayName(unknown: String) -> String {
        let parts = [artist, title].compactMap { $0 }
        return parts.isEmpty ? unknown : parts.joined(separator: " - ")
    }
}

/// The newest Serato session: what played, and which library tracks it used.
public struct SessionSummary: Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let startTime: Date
    public let isOpen: Bool
    public let tracks: [PlayedTrack]
    /// Every library track loaded in the session, played or not; suggestions leave these out.
    public let assetIDs: Set<Int64>

    public init(id: Int64, name: String, startTime: Date, isOpen: Bool, tracks: [PlayedTrack], assetIDs: Set<Int64>) {
        self.id = id
        self.name = name
        self.startTime = startTime
        self.isOpen = isOpen
        self.tracks = tracks
        self.assetIDs = assetIDs
    }
}

public enum Tracklist {
    /// Text to paste into a mix description.
    /// - With times: `00:00 Artist - Title`, counted from the first track.
    /// - Without: `1. Artist - Title`.
    /// `unknown` names a track with neither artist nor title.
    public static func text(_ tracks: [PlayedTrack], includeTimes: Bool, unknown: String = "(Unknown track)") -> String {
        guard let first = tracks.first?.startedAt else { return "" }
        return tracks.enumerated().map { index, track in
            let name = track.displayName(unknown: unknown)
            return includeTimes
                ? "\(timestamp(track.startedAt.timeIntervalSince(first))) \(name)"
                : "\(index + 1). \(name)"
        }.joined(separator: "\n")
    }

    /// `05:07`, or `1:02:03` past an hour.
    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}
