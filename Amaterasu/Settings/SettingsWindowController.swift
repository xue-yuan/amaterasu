import AppKit
import SwiftUI

/// The Settings window. An AppKit window rather than a SwiftUI `Settings` scene: in an LSUIElement
/// (no Dock icon) app the scene cannot be opened from code and opens behind other apps.
@MainActor
final class SettingsWindowController {
    private let controller: NotchController
    private var window: NSWindow?

    init(controller: NotchController) {
        self.controller = controller
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// The SwiftUI content follows the language by itself; the AppKit title does not.
    func languageDidChange() {
        window?.title = Self.title
    }

    private static var title: String { L10n.string("Amaterasu Settings") }

    #if DEBUG
    /// Renders the window's content to a PNG (it is this app's own view, so no screen-recording permission).
    func snapshot(to url: URL) {
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let view = self?.window?.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
    }
    #endif

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(controller: controller)))
        window.title = Self.title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
