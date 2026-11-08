#if DEBUG
import AppKit
import Domain
import Mock
import NotchLayout
import SeratoDatabase
import SwiftUI

/// Debug builds only: `Amaterasu --render-snapshots <dir>` renders the panel's states to PNGs and quits.
/// Lets the layout be checked without screen-recording permission.
@MainActor
enum SnapshotRenderer {
    static func renderIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--render-snapshots"), index + 1 < arguments.count else { return false }
        render(to: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
        return true
    }

    private struct Snapshot {
        let name: String
        let geometry: NotchGeometry
        let decks: [DeckState]
        let expanded: Bool
        var notation: KeyNotation = .camelot
        var includeAdvanced = false
        var isDemo = false
        var status: SeratoStatus = .notRunning
        var language: AppLanguage = .english
    }

    private static func render(to directory: URL) {
        let notched = NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            safeAreaTop: 32,
            topLeftArea: CGRect(x: 0, y: 1085, width: 771.5, height: 32),
            topRightArea: CGRect(x: 956.5, y: 1085, width: 771.5, height: 32),
            menuBarHeight: 33,
            fallbackWidth: 200
        )
        let plain = NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            safeAreaTop: 0, topLeftArea: nil, topRightArea: nil,
            menuBarHeight: 25, fallbackWidth: 200
        )
        let now = Date()
        func deck(_ id: Int, _ title: String, _ artist: String, _ bpm: Double?, _ key: String?, startedAgo: TimeInterval?) -> DeckState {
            DeckState(
                id: id, title: title, artist: artist, bpm: bpm, key: key.flatMap(KeyParser.parse),
                hasStartedPlaying: startedAgo != nil, loadedAt: now.addingTimeInterval(-(startedAgo ?? 30) - 10),
                playStartedAt: startedAgo.map { now.addingTimeInterval(-$0) }
            )
        }
        let main = deck(1, "Midnight Circuit", "Neon Harbor", 124, "8A", startedAgo: 290)
        var adjacent = deck(2, "An Extremely Long Track Title That Should Truncate Nicely (Extended Club Mix)", "Glass Avenue", 128, "9A", startedAgo: nil)
        adjacent.playedEarlierAt = now.addingTimeInterval(-3600)
        let relativeStretch = deck(2, "Low Orbit", "Sora Vale", 133, "8B", startedAgo: nil)
        let unanalysed = deck(3, "Unanalysed Demo", "Unknown Artist", nil, nil, startedAgo: nil)
        let clash = deck(4, "Hyperlight", "Juno Park", 140, "11B", startedAgo: 480)
        let halfTime = deck(2, "Slow Burn City", "The Fold", 62, "7A", startedAgo: nil)
        let semitone = deck(3, "Velvet Signal", "Orchid Unit", 122, "3A", startedAgo: nil)
        let unanalysedMain = deck(1, "Unanalysed Demo", "Unknown Artist", nil, nil, startedAgo: 60)

        let snapshots = [
            Snapshot(name: "1-collapsed-notch", geometry: notched, decks: [main, adjacent], expanded: false),
            Snapshot(name: "2-collapsed-notch-empty", geometry: notched, decks: [], expanded: false),
            Snapshot(name: "3-expanded-2-decks", geometry: notched, decks: [main, relativeStretch], expanded: true, isDemo: true),
            Snapshot(name: "4-expanded-4-decks", geometry: notched, decks: [main, adjacent, unanalysed, clash], expanded: true),
            Snapshot(name: "5-expanded-empty", geometry: notched, decks: [], expanded: true),
            Snapshot(name: "6-collapsed-capsule", geometry: plain, decks: [main, adjacent], expanded: false),
            Snapshot(name: "7-expanded-capsule", geometry: plain, decks: [main, adjacent], expanded: true),
            Snapshot(name: "8-advanced-openkey", geometry: notched, decks: [main, halfTime, semitone], expanded: true,
                     notation: .openKey, includeAdvanced: true),
            Snapshot(name: "9-main-without-key", geometry: notched, decks: [unanalysedMain, adjacent], expanded: true,
                     notation: .traditional),
            Snapshot(name: "10-empty-not-installed", geometry: notched, decks: [], expanded: true, status: .notInstalled),
            Snapshot(name: "11-empty-incompatible", geometry: notched, decks: [], expanded: true,
                     status: .incompatible(missing: ["history_entry.key_value"])),
            Snapshot(name: "12-zh-hant-4-decks", geometry: notched, decks: [main, adjacent, unanalysed, clash], expanded: true,
                     isDemo: true, language: .traditionalChinese),
            Snapshot(name: "13-zh-hant-advanced", geometry: notched, decks: [main, halfTime, semitone], expanded: true,
                     notation: .openKey, includeAdvanced: true, language: .traditionalChinese),
            Snapshot(name: "14-zh-hant-main-without-key", geometry: notched, decks: [unanalysedMain, adjacent], expanded: true,
                     language: .traditionalChinese),
            Snapshot(name: "15-zh-hant-empty", geometry: notched, decks: [], expanded: true, language: .traditionalChinese),
        ]
        for snapshot in snapshots {
            L10n.language = snapshot.language
            let settings = AppSettings(defaults: nil)
            settings.update {
                $0.keyNotation = snapshot.notation
                $0.includeAdvancedRecommendations = snapshot.includeAdvanced
            }
            let model = NotchViewModel(settings: settings)
            model.decks = snapshot.decks
            model.isExpanded = snapshot.expanded
            model.isDemo = snapshot.isDemo
            model.seratoStatus = snapshot.status
            if let main = model.mainDeck, let key = main.key {
                model.suggestions = TrackSuggester.suggest(
                    from: MockProvider.library, mainKey: key, mainBPM: main.bpm, includeAdvanced: snapshot.includeAdvanced
                )
            }
            model.hasHardwareNotch = snapshot.geometry.hasHardwareNotch
            model.notchSize = snapshot.geometry.notchRect.size
            model.collapsedSize = model.metrics.collapsedSize(for: snapshot.geometry, showsEars: model.mainDeck != nil)
            model.expandedSize = model.metrics.expandedSize(
                for: snapshot.geometry, deckCount: snapshot.decks.count, showsSuggestions: model.showsSuggestions
            )
            let size = snapshot.expanded ? model.expandedSize : model.collapsedSize

            // A grey "screen" so the black panel is visible; a faint outline marks the hardware notch.
            let view = ZStack(alignment: .top) {
                Color(white: 0.55)
                NotchRootView(model: model)
                    .frame(width: size.width, height: size.height)
                if snapshot.geometry.hasHardwareNotch {
                    Rectangle()
                        .stroke(Color.red.opacity(0.6), lineWidth: 0.5)
                        .frame(width: model.notchSize.width, height: model.notchSize.height)
                }
            }
            .frame(width: size.width + 60, height: size.height + 24)

            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else { continue }
            try? png.write(to: directory.appending(path: "\(snapshot.name).png"))
        }
    }
}
#endif
