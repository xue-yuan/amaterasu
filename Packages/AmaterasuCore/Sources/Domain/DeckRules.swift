import Foundation

public enum MainDeck {
    /// The deck the panel treats as "main":
    /// 1. the user's manual choice, if that deck is loaded;
    /// 2. otherwise the deck that started playing most recently;
    /// 3. otherwise the deck loaded most recently.
    /// Ties go to the lower deck number.
    public static func select(from decks: [DeckState], manual: Int? = nil) -> Int? {
        if let manual, decks.contains(where: { $0.id == manual }) {
            return manual
        }
        let started = decks.filter(\.hasStartedPlaying)
        if !started.isEmpty {
            return latest(started) { $0.playStartedAt ?? $0.loadedAt }
        }
        return latest(decks) { $0.loadedAt }
    }

    private static func latest(_ decks: [DeckState], by time: (DeckState) -> Date?) -> Int? {
        decks.min { a, b in
            let ta = time(a) ?? .distantPast
            let tb = time(b) ?? .distantPast
            return ta != tb ? ta > tb : a.id < b.id
        }?.id
    }
}

public enum TrackChanges {
    /// Deck numbers whose loaded track is new compared with `previous`: a newly loaded deck, or a different track.
    /// A track that merely starts playing is not a change.
    public static func changedDecks(from previous: [DeckState], to current: [DeckState]) -> [Int] {
        let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return current.compactMap { deck in
            guard let old = before[deck.id] else { return deck.id }
            let changed = old.loadedAt != deck.loadedAt || old.title != deck.title || old.artist != deck.artist
            return changed ? deck.id : nil
        }
    }
}
