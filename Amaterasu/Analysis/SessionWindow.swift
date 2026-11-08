import AppKit
import Charts
import Domain
import SeratoDatabase
import SwiftUI

/// "Session Analysis": any session's tempo curve, transitions, stats and tracklist.
@MainActor
final class SessionWindowController: NSObject, NSWindowDelegate {
    private let notch: NotchViewModel
    private var window: NSWindow?
    private var model: SessionWindowModel?

    init(notch: NotchViewModel) {
        self.notch = notch
    }

    func show() {
        let model = self.model ?? SessionWindowModel(notch: notch)
        self.model = model
        let window = self.window ?? makeWindow(model)
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        Task { await model.reload() }
    }

    /// The SwiftUI content follows the language by itself; the AppKit title does not.
    func languageDidChange() {
        window?.title = Self.title
    }

    private static var title: String { L10n.string("Session Analysis") }

    func windowWillClose(_ notification: Notification) {
        guard let model else { return }
        Task { await model.close() } // drops the private database copy, if any
    }

    #if DEBUG
    /// Renders the window's content to a PNG (this app's own view: no screen-recording permission needed),
    /// optionally after selecting a session.
    func snapshot(to url: URL, session: Int64? = nil) {
        show()
        if let session {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated { self?.model?.selectedID = session }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated {
                guard let view = self?.window?.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
    }
    #endif

    private func makeWindow(_ model: SessionWindowModel) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SessionView(model: model)))
        window.title = Self.title
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 900, height: 760))
        window.center()
        return window
    }
}

@MainActor
@Observable
final class SessionWindowModel {
    let notch: NotchViewModel
    private(set) var sessions: [SessionArchive.Session] = []
    private(set) var analysis: SetAnalysis?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    var selectedID: Int64? {
        didSet {
            guard selectedID != oldValue else { return }
            Task { await loadTracks() }
        }
    }

    @ObservationIgnored private let archive = SessionArchive()
    @ObservationIgnored private var generation = 0

    init(notch: NotchViewModel) {
        self.notch = notch
    }

    var selectedSession: SessionArchive.Session? {
        sessions.first { $0.id == selectedID }
    }

    /// Reloads the session list, keeping the selection (or picking the newest), then its tracks.
    func reload() async {
        do {
            let list = try await archive.sessions()
            sessions = list
            errorMessage = nil
            if let selectedID, list.contains(where: { $0.id == selectedID }) {
                await loadTracks()
            } else {
                selectedID = list.first?.id // loads through didSet
                if list.isEmpty { analysis = nil }
            }
        } catch {
            errorMessage = L10n.string("Can't read Serato's play history: \(String(describing: error))")
        }
    }

    func close() async {
        await archive.close()
    }

    private func loadTracks() async {
        guard let id = selectedID else { return }
        generation += 1
        let current = generation
        isLoading = true
        defer { if current == generation { isLoading = false } }
        do {
            let tracks = try await archive.tracks(sessionID: id)
            guard current == generation else { return }
            let isOpen = sessions.first { $0.id == id }?.isOpen ?? false
            analysis = SetAnalysis(tracks: tracks, now: isOpen ? Date() : nil)
            errorMessage = nil
        } catch {
            guard current == generation else { return }
            errorMessage = L10n.string("Can't read this session: \(String(describing: error))")
        }
    }
}

struct SessionView: View {
    @Bindable var model: SessionWindowModel
    @State private var selectedMinute: Double?
    @State private var selectedRow: Int?
    @State private var copiedMessage: String?

    var body: some View {
        Group {
            if let error = model.errorMessage, model.analysis == nil {
                ContentUnavailableView("Can't Read Play History", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if model.sessions.isEmpty {
                ContentUnavailableView(
                    "No Play History Yet",
                    systemImage: "chart.xyaxis.line",
                    description: Text("Once you've played tracks in Serato, each session's tempo curve and tracklist show up here.")
                )
            } else {
                content
            }
        }
        .frame(minWidth: 760, minHeight: 620)
        .appLanguage()
        // Tonight's session changes while Serato plays: keep the list and an open session current.
        .onChange(of: model.notch.session) {
            Task { await model.reload() }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let analysis = model.analysis {
                StatsRow(analysis: analysis)
                if analysis.tracks.contains(where: { $0.bpm != nil }) {
                    TempoChart(analysis: analysis, notation: model.notch.notation, selectedMinute: $selectedMinute)
                        .frame(height: 230)
                }
                SessionTable(analysis: analysis, notation: model.notch.notation, selection: $selectedRow)
                    .onChange(of: selectedRow) {
                        guard let row = selectedRow, let first = analysis.tracks.first?.startedAt,
                              analysis.tracks.indices.contains(row) else { return }
                        selectedMinute = analysis.tracks[row].startedAt.timeIntervalSince(first) / 60
                    }
            } else if model.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(18)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Picker("Session", selection: $model.selectedID) {
                ForEach(model.sessions) { session in
                    Text(sessionTitle(session)).tag(Optional(session.id))
                }
            }
            .frame(maxWidth: 340)
            if model.isLoading {
                ProgressView().controlSize(.small)
            }
            Spacer()
            if let copiedMessage {
                Text(copiedMessage).font(.caption).foregroundStyle(.secondary)
            }
            Button("Copy Tracklist with Times") { copy(includeTimes: true) }
            Button("Copy Tracklist") { copy(includeTimes: false) }
        }
    }

    private func sessionTitle(_ session: SessionArchive.Session) -> String {
        let time = Format.clock(session.startTime)
        let start = session.isOpen ? L10n.string("\(time) (live)") : time
        return "\(session.name) \(start) · \(L10n.tracks(session.trackCount))"
    }

    private func copy(includeTimes: Bool) {
        guard let tracks = model.analysis?.tracks, !tracks.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Tracklist.text(tracks, includeTimes: includeTimes, unknown: L10n.string("(Unknown track)")), forType: .string)
        copiedMessage = L10n.string("Copied \(L10n.tracks(tracks.count))")
    }
}

/// Six headline numbers.
private struct StatsRow: View {
    let analysis: SetAnalysis

    var body: some View {
        Grid(horizontalSpacing: 10) {
            GridRow {
                StatTile(title: "Duration", value: Format.duration(analysis.duration), detail: nil)
                StatTile(title: "Tracks", value: "\(analysis.tracks.count)", detail: L10n.string("Excludes < 30 s"))
                StatTile(title: "Avg per track", value: analysis.averageTrackDuration.map(Tracklist.timestamp) ?? "—", detail: nil)
                StatTile(
                    title: "Tempo range",
                    value: analysis.tempoRange.map { String(format: "%.0f–%.0f", $0.lowerBound, $0.upperBound) } ?? "—",
                    detail: analysis.averageTempo.map { L10n.string("Avg \(Int($0.rounded())) BPM") }
                )
                StatTile(
                    title: "Harmonic mixes",
                    value: analysis.harmonicShare.map { String(format: "%.0f%%", $0 * 100) } ?? "—",
                    detail: L10n.string("Jumps \(analysis.count(.keyJump)) · Boosts \(analysis.count(.energyBoost))")
                )
                StatTile(
                    title: "Biggest jump",
                    value: analysis.biggestTempoJump.map { String(format: "%+.0f%%", $0.percent) } ?? "—",
                    detail: analysis.biggestTempoJump.map { L10n.string("Into \(analysis.tracks[$0.trackIndex].title ?? L10n.string("track \($0.trackIndex + 1)"))") }
                )
            }
        }
    }
}

private struct StatTile: View {
    let title: LocalizedStringKey
    let value: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail ?? " ")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

/// How a transition is shown: label and chart symbol. Shape, not colour, tells transitions apart.
@MainActor
enum TransitionStyle {
    static var opening: String { L10n.string("Opener") }

    static func label(_ kind: SetTransition.Kind?) -> String {
        switch kind {
        case nil: opening
        case .harmonic?: L10n.string("Harmonic")
        case .energyBoost?: L10n.string("Energy boost")
        case .keyJump?: L10n.string("Key jump")
        case .unknownKey?: L10n.string("Unknown key")
        }
    }

    /// Keyed by `label`, so it follows the interface language.
    static var symbols: KeyValuePairs<String, BasicChartSymbolShape> {
        [
            opening: .diamond, label(.harmonic): .circle, label(.energyBoost): .triangle,
            label(.keyJump): .cross, label(.unknownKey): .square,
        ]
    }

    /// e.g. "Harmonic · Adjacent +2.4%"
    static func describe(_ transition: SetTransition?) -> String {
        guard let transition else { return opening }
        var text = label(transition.kind)
        if transition.kind != .keyJump, transition.kind != .unknownKey, let relation = transition.relation,
           relation.localizedLabel != text {
            text += " · \(relation.localizedLabel)"
        }
        if let change = transition.tempoChangePercent {
            let rounded = (change * 10).rounded() / 10
            text += rounded == 0 ? " 0.0%" : String(format: " %+.1f%%", rounded)
        }
        return text
    }
}

/// The set's tempo over time: a step line (a track keeps its tempo until the next one), one marker per
/// track shaped by how it was mixed in, and a hover read-out.
private struct TempoChart: View {
    let analysis: SetAnalysis
    let notation: KeyNotation
    @Binding var selectedMinute: Double?

    private struct Point: Identifiable {
        let id: Int
        let minute: Double
        let tempo: Double
        let kind: String
    }

    private var start: Date { analysis.tracks.first?.startedAt ?? Date() }

    private var points: [Point] {
        analysis.tracks.enumerated().compactMap { index, track in
            guard let bpm = track.bpm else { return nil }
            return Point(
                id: index,
                minute: track.startedAt.timeIntervalSince(start) / 60,
                tempo: analysis.setTempo(bpm),
                kind: TransitionStyle.label(index == 0 ? nil : analysis.transitions[index - 1].kind)
            )
        }
    }

    /// The step line runs on to the end of the set.
    private var line: [Point] {
        guard let last = points.last else { return [] }
        let end = max(analysis.duration / 60, last.minute)
        return points + [Point(id: -1, minute: end, tempo: last.tempo, kind: last.kind)]
    }

    private var yDomain: ClosedRange<Double> {
        guard let range = analysis.tempoRange else { return 60...140 }
        let padding = max(4, (range.upperBound - range.lowerBound) * 0.15)
        return (range.lowerBound - padding)...(range.upperBound + padding)
    }

    /// The track playing at the selected time.
    private var selectedIndex: Int? {
        guard let minute = selectedMinute else { return nil }
        return analysis.tracks.indices.last { analysis.tracks[$0].startedAt.timeIntervalSince(start) / 60 <= minute }
    }

    var body: some View {
        Chart {
            ForEach(line) { point in
                LineMark(x: .value("Time", point.minute), y: .value("BPM", point.tempo))
                    .interpolationMethod(.stepEnd)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .foregroundStyle(Color.accentColor.opacity(0.75))
            }
            ForEach(points) { point in
                PointMark(x: .value("Time", point.minute), y: .value("BPM", point.tempo))
                    .symbol(by: .value("Transition", point.kind))
                    .symbolSize(70)
                    .foregroundStyle(Color.accentColor)
            }
            if let index = selectedIndex {
                let minute = analysis.tracks[index].startedAt.timeIntervalSince(start) / 60
                RuleMark(x: .value("Time", minute))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        TrackReadout(analysis: analysis, index: index, notation: notation)
                    }
            }
        }
        .chartSymbolScale(TransitionStyle.symbols)
        .chartXSelection(value: $selectedMinute)
        .chartYScale(domain: yDomain)
        .chartYAxisLabel("BPM (half / double time folded to this set)")
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 8)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let minute = value.as(Double.self) {
                        Text(Format.setClock(minutes: minute))
                    }
                }
            }
        }
        .chartLegend(position: .top, alignment: .leading)
    }
}

/// Hover read-out for one track.
private struct TrackReadout: View {
    let analysis: SetAnalysis
    let index: Int
    let notation: KeyNotation

    var body: some View {
        let track = analysis.tracks[index]
        VStack(alignment: .leading, spacing: 2) {
            Text("\(Format.clock(track.startedAt)) · Track \(index + 1)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(track.displayName(unknown: L10n.string("(Unknown track)")))
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text("\(SessionTable.tempoText(track, analysis)) · \(track.key?.formatted(notation) ?? "—") · \(TransitionStyle.describe(index == 0 ? nil : analysis.transitions[index - 1]))")
                .font(.caption2)
                .monospacedDigit()
        }
        .padding(8)
        .frame(maxWidth: 320, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(.background).shadow(radius: 2))
    }
}

/// The tracklist with how each track was mixed in.
private struct SessionTable: View {
    let analysis: SetAnalysis
    let notation: KeyNotation
    @Binding var selection: Int?

    private struct Row: Identifiable {
        let id: Int
        let track: PlayedTrack
        let transition: SetTransition?
    }

    private var rows: [Row] {
        analysis.tracks.enumerated().map { index, track in
            Row(id: index, track: track, transition: index == 0 ? nil : analysis.transitions[index - 1])
        }
    }

    /// The set tempo, with Serato's own value when it was doubled or halved, e.g. "75.0 (150.1)".
    static func tempoText(_ track: PlayedTrack, _ analysis: SetAnalysis) -> String {
        guard let bpm = track.bpm else { return "—" }
        let tempo = analysis.setTempo(bpm)
        return abs(tempo - bpm) < 0.05 ? String(format: "%.1f", bpm) : String(format: "%.1f (%.1f)", tempo, bpm)
    }

    var body: some View {
        let first = analysis.tracks.first?.startedAt ?? Date()
        Table(rows, selection: $selection) {
            TableColumn("#") { row in
                Text("\(row.id + 1)").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(28)
            TableColumn("Time") { row in
                Text(Tracklist.timestamp(row.track.startedAt.timeIntervalSince(first))).monospacedDigit()
            }
            .width(64)
            TableColumn("Track") { row in
                Text(row.track.displayName(unknown: L10n.string("(Unknown track)")))
            }
            TableColumn("BPM") { row in
                Text(Self.tempoText(row.track, analysis)).monospacedDigit()
            }
            .width(100)
            TableColumn("Key") { row in
                Text(row.track.key?.formatted(notation) ?? "—").monospacedDigit()
            }
            .width(48)
            TableColumn("Transition") { row in
                Text(TransitionStyle.describe(row.transition)).monospacedDigit()
            }
            .width(200)
        }
    }
}
