import AppKit
import SwiftUI

@main
struct AmaterasuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Amaterasu", systemImage: "rectangle.topthird.inset.filled") {
            MenuContent(controller: appDelegate.controller)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = NotchController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if SnapshotRenderer.renderIfRequested() {
            NSApp.terminate(nil)
            return
        }
        #endif
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }
}

/// The menu bar icon's menu. Titles are resolved with `L10n.string` rather than left to SwiftUI, since
/// the menu becomes an AppKit `NSMenu`.
struct MenuContent: View {
    /// Demo mode (MockProvider) is hidden for now. Set to true to bring back its menu items.
    private static let showsDemoMode = false

    let controller: NotchController

    var body: some View {
        let model = controller.model
        Text(L10n.string("Serato: \(StatusText.short(model.seratoStatus))"))
        Button(L10n.string("Expand / Collapse Panel (\(controller.settings.preferences.hotKey.display))")) { controller.togglePanel() }
        Button(sessionsTitle(model)) { controller.showSessions() }
        Button(L10n.string("Settings…")) { controller.showSettings() }
            .keyboardShortcut(",")
        if Self.showsDemoMode {
            Divider()
            Toggle(L10n.string("Demo Mode (Fake Data)"), isOn: Binding(get: { model.isDemo }, set: { controller.setDemoMode($0) }))
            if model.isDemo {
                Button(L10n.string("Simulate Track Change")) { controller.simulateTrackChange() }
                Picker(L10n.string("Number of Decks"), selection: Binding(get: { model.mockDeckCount }, set: { controller.setMockDeckCount($0) })) {
                    ForEach(1...4, id: \.self) { count in
                        Text(L10n.string("\(count) decks")).tag(count)
                    }
                }
            }
        }
        Divider()
        Button(L10n.string("Quit Amaterasu")) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func sessionsTitle(_ model: NotchViewModel) -> String {
        let count = model.session?.tracks.count ?? 0
        return count > 0
            ? L10n.string("Session Analysis & Tracklists (\(L10n.tracks(count)) tonight)…")
            : L10n.string("Session Analysis & Tracklists…")
    }
}
