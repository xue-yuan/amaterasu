import CoreGraphics
import Foundation
import XCTest
@testable import NotchLayout

final class NotchGeometryTests: XCTestCase {
    /// The built-in display of the development MacBook, as reported by NSScreen.
    private let builtIn = NotchGeometry(
        screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        safeAreaTop: 32,
        topLeftArea: CGRect(x: 0, y: 1085, width: 771.5, height: 32),
        topRightArea: CGRect(x: 956.5, y: 1085, width: 771.5, height: 32),
        menuBarHeight: 33,
        fallbackWidth: 200
    )

    func testFindsTheHardwareNotch() {
        XCTAssertTrue(builtIn.hasHardwareNotch)
        XCTAssertEqual(builtIn.notchRect, CGRect(x: 771.5, y: 1085, width: 185, height: 32))
    }

    func testAcceptsAuxiliaryAreasRelativeToAnOffsetScreen() {
        let frame = CGRect(x: -1728, y: 0, width: 1728, height: 1117)
        let relative = NotchGeometry(
            screenFrame: frame, safeAreaTop: 32,
            topLeftArea: CGRect(x: 0, y: 1085, width: 771.5, height: 32),
            topRightArea: CGRect(x: 956.5, y: 1085, width: 771.5, height: 32),
            menuBarHeight: 33, fallbackWidth: 200
        )
        let global = NotchGeometry(
            screenFrame: frame, safeAreaTop: 32,
            topLeftArea: CGRect(x: -1728, y: 1085, width: 771.5, height: 32),
            topRightArea: CGRect(x: -771.5, y: 1085, width: 771.5, height: 32),
            menuBarHeight: 33, fallbackWidth: 200
        )
        XCTAssertEqual(relative.notchRect, CGRect(x: -956.5, y: 1085, width: 185, height: 32))
        XCTAssertEqual(global.notchRect, relative.notchRect)
    }

    func testScreensWithoutANotchGetACentredCapsule() {
        let external = NotchGeometry(
            screenFrame: CGRect(x: 1728, y: 0, width: 2560, height: 1440),
            safeAreaTop: 0, topLeftArea: nil, topRightArea: nil,
            menuBarHeight: 25, fallbackWidth: 200
        )
        XCTAssertFalse(external.hasHardwareNotch)
        XCTAssertEqual(external.notchRect, CGRect(x: 1728 + 1280 - 100, y: 1415, width: 200, height: 25))
    }

    func testPanelHangsFromTheTopCentredOnTheNotch() {
        let frame = builtIn.panelFrame(for: CGSize(width: 400, height: 150))
        XCTAssertEqual(frame, CGRect(x: 864 - 200, y: 1117 - 150, width: 400, height: 150))
    }

    func testPanelStaysOnScreen() {
        let narrow = NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 300, height: 800),
            safeAreaTop: 0, topLeftArea: nil, topRightArea: nil,
            menuBarHeight: 24, fallbackWidth: 200
        )
        XCTAssertEqual(narrow.panelFrame(for: CGSize(width: 500, height: 100)).minX, 0)
        XCTAssertEqual(narrow.panelFrame(for: CGSize(width: 500, height: 100)).width, 300)
    }

    func testSizes() {
        let metrics = PanelMetrics()
        XCTAssertEqual(metrics.collapsedSize(for: builtIn, showsEars: false), CGSize(width: 185 + 12, height: 32))
        XCTAssertEqual(metrics.collapsedSize(for: builtIn, showsEars: true), CGSize(width: 185 + 144 + 12, height: 32))
        // Two cards (346) are narrower than the recommendation row needs (420).
        XCTAssertEqual(metrics.expandedSize(for: builtIn, deckCount: 2), CGSize(width: 420 + 32 + 12, height: 32 + 166))
        XCTAssertEqual(metrics.expandedSize(for: builtIn, deckCount: 4).width, 4 * 168 + 30 + 32 + 12)
        XCTAssertEqual(metrics.expandedSize(for: builtIn, deckCount: 2, showsSuggestions: true).height, 32 + 166 + 78)
        XCTAssertEqual(metrics.expandedSize(for: builtIn, deckCount: 0, showsSuggestions: true).height, 32 + 52, "no suggestions without decks")
        // With nothing loaded the panel is at least as wide as the notch plus its ears.
        XCTAssertEqual(metrics.expandedSize(for: builtIn, deckCount: 0), CGSize(width: 185 + 144 + 12, height: 32 + 52))
    }
}

final class NotchPresentationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testHoverExpandsAfterTheDelayAndLingersAfterLeaving() {
        var p = NotchPresentation()
        p.pointerEntered(at: at(0))
        XCTAssertFalse(p.isExpanded(at: at(0.05)))
        XCTAssertEqual(p.nextDeadline(after: at(0.05)), at(0.12))
        XCTAssertTrue(p.isExpanded(at: at(0.12)))

        p.pointerExited(at: at(2))
        XCTAssertTrue(p.isExpanded(at: at(2.2)))
        XCTAssertEqual(p.nextDeadline(after: at(2.2)), at(2.35))
        XCTAssertFalse(p.isExpanded(at: at(2.35)))
    }

    func testAPassingPointerDoesNotExpand() {
        var p = NotchPresentation()
        p.pointerEntered(at: at(0))
        p.pointerExited(at: at(0.05))
        XCTAssertFalse(p.isExpanded(at: at(0.05)))
        XCTAssertNil(p.nextDeadline(after: at(0.05)))
    }

    func testReenteringDuringTheGraceKeepsItOpen() {
        var p = NotchPresentation()
        p.pointerEntered(at: at(0))
        p.pointerExited(at: at(1))
        p.pointerEntered(at: at(1.1))
        XCTAssertTrue(p.isExpanded(at: at(1.15)))
        XCTAssertTrue(p.isExpanded(at: at(5)))
    }

    func testTrackChangePeeksForFourSeconds() {
        var p = NotchPresentation()
        p.trackChanged(at: at(0))
        XCTAssertTrue(p.isExpanded(at: at(3.9)))
        XCTAssertEqual(p.nextDeadline(after: at(1)), at(4))
        XCTAssertFalse(p.isExpanded(at: at(4)))
    }

    func testHoveringKeepsAPeekOpen() {
        var p = NotchPresentation()
        p.trackChanged(at: at(0))
        p.pointerEntered(at: at(1))
        XCTAssertTrue(p.isExpanded(at: at(10)))
        p.pointerExited(at: at(10))
        XCTAssertFalse(p.isExpanded(at: at(10.35)))
    }

    func testPeekCanBeDisabled() {
        var p = NotchPresentation()
        p.autoExpandOnTrackChange = false
        p.trackChanged(at: at(0))
        XCTAssertFalse(p.isExpanded(at: at(1)))
    }

    func testTogglePinsOpenAndClosesEverything() {
        var p = NotchPresentation()
        p.toggle(at: at(0))
        XCTAssertTrue(p.isExpanded(at: at(100)))
        p.trackChanged(at: at(100))
        p.toggle(at: at(101))
        XCTAssertFalse(p.isExpanded(at: at(101)), "closing also cancels the peek")
    }

    func testClosingWhileHoveringIgnoresThatHoverUntilThePointerLeaves() {
        var p = NotchPresentation()
        p.pointerEntered(at: at(0))
        XCTAssertTrue(p.isExpanded(at: at(1)))
        p.toggle(at: at(1))
        XCTAssertFalse(p.isExpanded(at: at(2)))
        XCTAssertNil(p.nextDeadline(after: at(2)))
        p.pointerExited(at: at(3))
        p.pointerEntered(at: at(4))
        XCTAssertTrue(p.isExpanded(at: at(4.2)))
    }
}
