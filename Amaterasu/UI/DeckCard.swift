import Domain
import SwiftUI

struct DeckCard: View {
    let deck: DeckState
    let isMain: Bool
    let isManualMain: Bool
    /// Against the main deck; nil on the main deck itself.
    let comparison: DeckComparison?
    let notation: KeyNotation
    let width: CGFloat

    private var borderColor: Color {
        if isMain { return .white.opacity(0.35) }
        if comparison?.keyRelation != nil { return .green.opacity(0.55) }
        return .clear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                StatusDot(started: deck.hasStartedPlaying)
                Text("DECK \(deck.id)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 0)
                if isMain {
                    Text(isManualMain ? "MAIN · MANUAL" : "MAIN")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.85)))
                }
            }
            Text(deck.title ?? "—")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(deck.title ?? "")
            HStack(spacing: 6) {
                Text(deck.artist ?? "—")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let earlier = deck.playedEarlierAt {
                    RepeatBadge(playedAt: earlier)
                }
            }
            HStack(spacing: 8) {
                Text(Format.bpm(deck.bpm))
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                KeyBadge(key: deck.key, notation: notation)
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
            ComparisonLine(comparison: comparison, isMain: isMain)
                .padding(.top, 1)
        }
        .padding(10)
        // Cards share the panel width evenly, so two decks are as wide as the recommendation row.
        .frame(minWidth: width, maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(isMain ? 0.13 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

/// "✓ Adjacent · −3.1%": whether the deck's key mixes with the main deck, and the pitch change its tempo needs.
struct ComparisonLine: View {
    let comparison: DeckComparison?
    let isMain: Bool

    var body: some View {
        HStack(spacing: 4) {
            if let comparison {
                keyStatus(comparison)
                Spacer(minLength: 4)
                bpmStatus(comparison.bpm)
            } else {
                Text(isMain ? "Reference" : " ")
                    .foregroundStyle(.white.opacity(0.4))
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .lineLimit(1)
    }

    @ViewBuilder
    private func keyStatus(_ comparison: DeckComparison) -> some View {
        if !comparison.keysKnown {
            Text("Key —").foregroundStyle(.white.opacity(0.4))
        } else if let relation = comparison.keyRelation {
            Text(verbatim: "✓ \(relation.localizedLabel)").foregroundStyle(.green)
        } else {
            Text("✗ Key clash").foregroundStyle(.orange.opacity(0.85))
        }
    }

    @ViewBuilder
    private func bpmStatus(_ match: BPMMatch?) -> some View {
        if let match {
            Text(BPMText.difference(match))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(BPMText.color(match.level))
        } else {
            Text("BPM —").foregroundStyle(.white.opacity(0.4))
        }
    }
}

enum BPMText {
    /// e.g. `-3.1%`, `+0.0% ×2`
    static func difference(_ match: BPMMatch) -> String {
        // Round first so a tiny difference reads "0.0%", not "-0.0%".
        let rounded = (match.pitchPercent * 10).rounded() / 10
        let percent = rounded == 0 ? "0.0%" : String(format: "%+.1f%%", rounded)
        switch match.ratio {
        case .normal: return percent
        case .double: return percent + " ×2"
        case .half: return percent + " ×½"
        }
    }

    /// Green = within range, yellow = needs a big pitch change, grey = not compatible.
    static func color(_ level: BPMMatch.Level) -> Color {
        switch level {
        case .compatible: .green
        case .stretch: .yellow
        case .incompatible: .white.opacity(0.4)
        }
    }
}

/// "↺ 21:03": this track already played earlier tonight.
struct RepeatBadge: View {
    let playedAt: Date

    var body: some View {
        Text("↺ \(Format.clock(playedAt))")
            .font(.system(size: 9, weight: .heavy, design: .monospaced))
            .foregroundStyle(.black)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.orange.opacity(0.9)))
            .fixedSize()
            .help(L10n.string("Already played tonight at \(Format.clock(playedAt))"))
    }
}

/// One suggested track: key, BPM, pitch change, title — artist, and how it relates to the main key.
struct SuggestionRow: View {
    let suggestion: TrackSuggestion
    let notation: KeyNotation

    var body: some View {
        let track = suggestion.track
        HStack(spacing: 8) {
            Text(track.key?.formatted(notation) ?? "—")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(track.key.map(KeyColor.color) ?? .white.opacity(0.5))
                .frame(width: 34, alignment: .leading)
            Text(Format.bpm(track.bpm))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 40, alignment: .trailing)
            Text(suggestion.bpm.map(BPMText.difference) ?? "")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(suggestion.bpm.map { BPMText.color($0.level) } ?? .clear)
                .frame(width: 52, alignment: .leading)
            Text(track.title ?? "—")
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .layoutPriority(1)
            Text(track.artist ?? "")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(suggestion.relation.localizedLabel)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize()
        }
        .help([track.artist, track.title].compactMap { $0 }.joined(separator: " - "))
    }
}

/// A recommended key: the key, its relation, and the decks already loaded in it.
struct KeyChip: View {
    let recommendation: KeyRecommendation
    let notation: KeyNotation
    let compact: Bool
    let matchingDecks: [Int]

    var body: some View {
        HStack(spacing: 4) {
            Text(recommendation.key.formatted(notation))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(KeyColor.color(recommendation.key))
            if !compact {
                Text(recommendation.relation.localizedLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
            }
            ForEach(matchingDecks, id: \.self) { id in
                Text("D\(id)")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 3)
                    .background(Capsule().fill(Color.green.opacity(0.9)))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .overlay(Capsule().strokeBorder(matchingDecks.isEmpty ? Color.clear : Color.green.opacity(0.6), lineWidth: 1))
        .fixedSize()
        .help(recommendation.relation.localizedLabel)
    }
}

struct KeyBadge: View {
    let key: MusicalKey?
    let notation: KeyNotation

    var body: some View {
        Text(key?.formatted(notation) ?? "—")
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundStyle(key == nil ? Color.white.opacity(0.6) : Color.black)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(key.map(KeyColor.color) ?? Color.white.opacity(0.12)))
    }
}

/// Filled = the track has started playing; hollow = loaded but not played yet.
struct StatusDot: View {
    let started: Bool

    var body: some View {
        Circle()
            .fill(started ? Color.green : Color.clear)
            .overlay(Circle().strokeBorder(started ? Color.green : Color.white.opacity(0.6), lineWidth: 1.2))
            .frame(width: 7, height: 7)
            .help(started ? L10n.string("Playing") : L10n.string("Loaded, not played yet"))
    }
}

/// One hue per Camelot number so compatible keys are easy to spot; minor keys slightly more saturated.
enum KeyColor {
    static func color(_ key: MusicalKey) -> Color {
        Color(hue: Double(key.number - 1) / 12, saturation: key.isMinor ? 0.55 : 0.38, brightness: 0.96)
    }
}
