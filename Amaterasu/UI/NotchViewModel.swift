import CoreGraphics
import Domain
import NotchLayout
import Observation
import SeratoDatabase

/// Everything the notch views render. Owned by `NotchController`, mutated on the main actor only.
@MainActor
@Observable
final class NotchViewModel {
    let settings: AppSettings
    var decks: [DeckState] = []
    var manualMainDeckID: Int?
    var isExpanded = false
    /// The decks come from MockProvider, not Serato.
    var isDemo = true
    var seratoStatus: SeratoStatus = .notRunning
    /// "Next track" suggestions for the main deck.
    var suggestions: [TrackSuggestion] = []
    /// The last attempt to read suggestions from Serato's library failed.
    var suggestionsUnavailable = false
    /// The newest Serato session (tracklist, loaded tracks); kept after Serato quits.
    var session: SessionSummary?
    /// Called when the user picks or clears the main deck by hand.
    @ObservationIgnored var onMainDeckChange: (() -> Void)?

    // Geometry, kept in sync by NotchPanelController.
    var hasHardwareNotch = true
    var notchSize = CGSize(width: 185, height: 32)
    var collapsedSize = CGSize(width: 197, height: 32)
    var expandedSize = CGSize(width: 400, height: 150)
    let metrics = PanelMetrics()

    // Demo data choice shown in the menu bar menu.
    var mockDeckCount = 2

    init(settings: AppSettings) {
        self.settings = settings
    }

    var notation: KeyNotation { settings.preferences.keyNotation }
    var includeAdvanced: Bool { settings.preferences.includeAdvancedRecommendations }
    var bpmThresholds: BPMThresholds { settings.preferences.bpmThresholds }
    var showsSuggestions: Bool { settings.preferences.showSuggestions }

    /// Shown instead of the suggestion rows when there are none.
    var suggestionsMessage: String? {
        guard suggestions.isEmpty else { return nil }
        if mainDeck?.key == nil { return L10n.string("Main deck has no key data") }
        return suggestionsUnavailable
            ? L10n.string("Can't read the Serato library right now")
            : L10n.string("No library tracks match both key and BPM")
    }

    var mainDeckID: Int? { MainDeck.select(from: decks, manual: manualMainDeckID) }
    var mainDeck: DeckState? { decks.first { $0.id == mainDeckID } }

    func toggleManualMain(_ id: Int) {
        manualMainDeckID = manualMainDeckID == id ? nil : id
        onMainDeckChange?()
    }

    /// Keys that mix well after the main deck's key.
    var recommendations: [KeyRecommendation] {
        guard let key = mainDeck?.key else { return [] }
        return HarmonicRecommender.recommendations(for: key, includeAdvanced: includeAdvanced)
    }

    /// How a deck compares with the main deck; nil for the main deck itself.
    func comparison(for deck: DeckState) -> DeckComparison? {
        guard let main = mainDeck, main.id != deck.id else { return nil }
        var relation: KeyRelation?
        if let mainKey = main.key, let key = deck.key {
            relation = HarmonicRecommender.relation(from: mainKey, to: key, includeAdvanced: includeAdvanced)
        }
        return DeckComparison(
            keysKnown: main.key != nil && deck.key != nil,
            keyRelation: relation,
            bpm: BPMCompat.match(base: main.bpm, other: deck.bpm, thresholds: bpmThresholds)
        )
    }

    /// Decks other than the main one whose loaded track is in `key`.
    func otherDecks(inKey key: MusicalKey) -> [Int] {
        decks.filter { $0.id != mainDeckID && $0.key == key }.map(\.id)
    }
}

struct DeckComparison: Equatable {
    /// Both decks have an analysed key.
    let keysKnown: Bool
    /// Set when this deck's key is one of the main deck's recommendations.
    let keyRelation: KeyRelation?
    let bpm: BPMMatch?
}
