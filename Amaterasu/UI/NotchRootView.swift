import Domain
import SwiftUI

/// Root of the panel. The panel window is sized by NotchPanelController; this view draws the black notch
/// shape at the model's collapsed or expanded size, centred at the top, and animates between the two.
struct NotchRootView: View {
    let model: NotchViewModel

    var body: some View {
        let size = model.isExpanded ? model.expandedSize : model.collapsedSize
        let shape = NotchShape(topFlare: model.metrics.topFlare, bottomRadius: model.isExpanded ? 20 : 9)

        ZStack(alignment: .top) {
            shape.fill(Color.black)
            Group {
                if model.isExpanded {
                    ExpandedContent(model: model)
                        .transition(.opacity.combined(with: .offset(y: -6)))
                } else {
                    CollapsedContent(model: model)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, model.metrics.topFlare)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .appLanguage()
    }
}

/// Collapsed: the main deck's number beside the notch on the left, its Key and BPM on the right.
/// On screens without a notch everything sits inside the capsule.
private struct CollapsedContent: View {
    let model: NotchViewModel

    var body: some View {
        if let deck = model.mainDeck {
            if model.hasHardwareNotch {
                HStack(spacing: 0) {
                    deckLabel(deck)
                        .frame(width: model.metrics.earWidth)
                    Color.clear
                        .frame(width: model.notchSize.width)
                    keyAndBPM(deck)
                        .frame(width: model.metrics.earWidth)
                }
                .frame(height: model.notchSize.height)
            } else {
                HStack(spacing: 10) {
                    deckLabel(deck)
                    keyAndBPM(deck)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if !model.hasHardwareNotch {
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func deckLabel(_ deck: DeckState) -> some View {
        HStack(spacing: 5) {
            StatusDot(started: deck.hasStartedPlaying)
            Text("D\(deck.id)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func keyAndBPM(_ deck: DeckState) -> some View {
        HStack(spacing: 6) {
            Text(deck.key?.formatted(model.notation) ?? "—")
                .foregroundStyle(deck.key.map(KeyColor.color) ?? .white.opacity(0.5))
            Text(Format.bpm(deck.bpm))
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .lineLimit(1)
        .fixedSize()
    }
}

/// Expanded: one card per loaded deck, or a waiting message.
private struct ExpandedContent: View {
    let model: NotchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The strip beside the notch; the demo tag sits in its left part, clear of the notch.
            HStack {
                if model.isDemo {
                    Text("DEMO")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.85)))
                        .help(L10n.string("Showing fake demo data. Turn off Demo Mode from the menu bar icon's menu."))
                }
                Spacer()
            }
            .frame(height: model.notchSize.height)
            if model.decks.isEmpty {
                Text(StatusText.panelMessage(model.seratoStatus))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: model.metrics.deckSpacing) {
                    ForEach(model.decks) { deck in
                        DeckCard(
                            deck: deck,
                            isMain: deck.id == model.mainDeckID,
                            isManualMain: deck.id == model.manualMainDeckID,
                            comparison: model.comparison(for: deck),
                            notation: model.notation,
                            width: model.metrics.deckWidth
                        )
                        .onTapGesture { model.toggleManualMain(deck.id) }
                    }
                }
                .padding(.top, 6)
                RecommendationRow(model: model)
                    .padding(.top, 9)
                if model.showsSuggestions {
                    SuggestionsSection(model: model)
                        .padding(.top, 10)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, model.metrics.horizontalPadding)
    }
}

/// "Mix into" followed by the main deck's recommended keys; chips drop their labels if they do not fit.
private struct RecommendationRow: View {
    let model: NotchViewModel

    var body: some View {
        let recommendations = model.recommendations
        HStack(spacing: 6) {
            Text("Mix into")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
            if recommendations.isEmpty {
                Text("Main deck has no key data")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                ViewThatFits(in: .horizontal) {
                    chips(recommendations, compact: false)
                    chips(recommendations, compact: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func chips(_ recommendations: [KeyRecommendation], compact: Bool) -> some View {
        HStack(spacing: 5) {
            ForEach(recommendations, id: \.key) { recommendation in
                KeyChip(
                    recommendation: recommendation,
                    notation: model.notation,
                    compact: compact,
                    matchingDecks: model.otherDecks(inKey: recommendation.key)
                )
            }
        }
    }
}

/// "Suggested next": up to three library tracks that mix well after the main deck.
private struct SuggestionsSection: View {
    let model: NotchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Suggested next")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
            if let message = model.suggestionsMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                ForEach(model.suggestions) { suggestion in
                    SuggestionRow(suggestion: suggestion, notation: model.notation)
                }
            }
        }
    }
}

enum Format {
    static func bpm(_ bpm: Double?) -> String {
        guard let bpm else { return "—" }
        return String(format: "%.1f", bpm)
    }

    /// `21:03`, always 24-hour: the locale's style would give `09:03` with no AM / PM on a 12-hour system.
    static func clock(_ date: Date) -> String {
        date.formatted(Date.VerbatimFormatStyle(
            format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            timeZone: .current,
            calendar: Calendar(identifier: .gregorian)
        ))
    }

    /// Minutes into a set as `0:45`, `1:05`.
    static func setClock(minutes: Double) -> String {
        let total = max(0, Int(minutes.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// `1 h 01 min`, `38 min`
    @MainActor
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        guard minutes >= 60 else { return L10n.string("\(minutes) min") }
        return L10n.string("\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min")
    }
}
