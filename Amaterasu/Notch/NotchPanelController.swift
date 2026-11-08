import AppKit
import NotchLayout
import SwiftUI

/// Owns the panel window: puts it over the notch of the chosen screen, keeps its frame in step with the
/// collapsed / expanded state, and reports pointer enter / exit.
///
/// The window frame always matches what is visible (plus a short overlap during animations), so the
/// collapsed panel never blocks clicks below the notch.
@MainActor
final class NotchPanelController {
    private let model: NotchViewModel
    private let panel = NotchPanel()
    private var geometry: NotchGeometry?
    private static let settleDelay: TimeInterval = 0.5

    init(model: NotchViewModel, onPointerChange: @escaping @MainActor (Bool) -> Void) {
        self.model = model
        // The hosting view lives inside a plain container that follows the window by autoresizing.
        // As the window's contentView it would feed SwiftUI sizes and the notch's safe area back into
        // window constraints, which loops ("more Update Constraints in Window passes than there are views").
        let hostingView = NotchHostingView(rootView: NotchRootView(model: model))
        hostingView.sizingOptions = []
        hostingView.safeAreaRegions = []
        hostingView.autoresizingMask = [.width, .height]
        let container = NotchContainerView()
        container.onPointerChange = onPointerChange
        container.addSubview(hostingView)
        panel.contentView = container
        hostingView.frame = container.bounds

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateGeometry() }
        }
        updateGeometry()
    }

    /// Re-reads the target screen (built-in by default) and repositions the panel.
    func updateGeometry() {
        let preferences = model.settings.preferences
        guard let screen = ScreenLocator.screen(preferringUUID: preferences.preferredDisplayUUID) else {
            panel.orderOut(nil)
            return
        }
        let geometry = NotchGeometry(
            screenFrame: screen.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            topLeftArea: screen.auxiliaryTopLeftArea,
            topRightArea: screen.auxiliaryTopRightArea,
            menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY,
            fallbackWidth: CGFloat(preferences.fallbackCapsuleWidth)
        )
        self.geometry = geometry
        model.hasHardwareNotch = geometry.hasHardwareNotch
        model.notchSize = geometry.notchRect.size
        updateSizes()
        panel.setFrame(targetFrame(), display: true)
        panel.orderFrontRegardless()
    }

    func setExpanded(_ expanded: Bool) {
        guard expanded != model.isExpanded else { return }
        transition(expanded ? .spring(response: 0.36, dampingFraction: 0.8) : .spring(response: 0.3, dampingFraction: 0.95)) {
            model.isExpanded = expanded
        }
    }

    /// Call after the decks change: the expanded width and the collapsed "ears" depend on them.
    func contentDidChange() {
        transition(.spring(response: 0.36, dampingFraction: 0.85)) {
            updateSizes()
        }
    }

    /// Animates a model change. The window grows at once to cover both the old and new size, and
    /// shrinks to the new size once the animation has settled.
    private func transition(_ animation: Animation, _ change: () -> Void) {
        let before = panel.frame.size
        withAnimation(animation, change)
        guard let geometry else { return }
        let after = targetSize()
        let covering = CGSize(width: max(before.width, after.width), height: max(before.height, after.height))
        panel.setFrame(geometry.panelFrame(for: covering), display: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panel.setFrame(self.targetFrame(), display: true)
            }
        }
    }

    private func updateSizes() {
        guard let geometry else { return }
        model.collapsedSize = model.metrics.collapsedSize(for: geometry, showsEars: model.mainDeck != nil)
        model.expandedSize = model.metrics.expandedSize(
            for: geometry,
            deckCount: model.decks.count,
            showsSuggestions: model.showsSuggestions
        )
    }

    private func targetSize() -> CGSize {
        model.isExpanded ? model.expandedSize : model.collapsedSize
    }

    private func targetFrame() -> CGRect {
        geometry?.panelFrame(for: targetSize()) ?? .zero
    }
}

/// Borderless, non-activating, and never key: Serato is driven by the keyboard, so the panel must never
/// take focus away from it.
final class NotchPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Not `isFloatingPanel`: setting it resets the level to `.floating`.
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit would push the window below the menu bar; the panel belongs over the notch.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Hosts the SwiftUI content and accepts clicks without activating the app.
final class NotchHostingView: NSHostingView<NotchRootView> {
    required init(rootView: NotchRootView) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The panel's content view: tracks the pointer over the whole panel.
final class NotchContainerView: NSView {
    var onPointerChange: (@MainActor (Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onPointerChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onPointerChange?(false)
    }
}

enum ScreenLocator {
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// A display's UUID: unlike the display ID, it stays the same across reboots and reconnections.
    static func uuid(of screen: NSScreen) -> String? {
        guard let id = displayID(of: screen),
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// Connected displays for the Settings picker.
    static func displays() -> [(uuid: String, name: String)] {
        NSScreen.screens.compactMap { screen in
            uuid(of: screen).map { ($0, screen.localizedName) }
        }
    }

    /// The preferred display if connected, otherwise the built-in display, otherwise the main screen.
    static func screen(preferringUUID preferred: String?) -> NSScreen? {
        let screens = NSScreen.screens
        if let preferred, let match = screens.first(where: { uuid(of: $0) == preferred }) {
            return match
        }
        let builtIn = screens.first { screen in
            displayID(of: screen).map { CGDisplayIsBuiltin($0) != 0 } ?? false
        }
        return builtIn ?? NSScreen.main ?? screens.first
    }
}
