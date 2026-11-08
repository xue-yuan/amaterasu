import Foundation
import XCTest
@testable import Domain

final class PreferencesTests: XCTestCase {
    func testDefaultsMatchTheSpec() {
        let preferences = Preferences()
        XCTAssertEqual(preferences.keyNotation, .camelot)
        XCTAssertEqual(preferences.bpmThresholds, BPMThresholds(compatible: 6, stretch: 10))
        XCTAssertFalse(preferences.includeAdvancedRecommendations)
        XCTAssertTrue(preferences.autoExpandOnTrackChange)
        XCTAssertTrue(preferences.showSuggestions)
        XCTAssertEqual(preferences.fallbackCapsuleWidth, 200)
        XCTAssertNil(preferences.preferredDisplayUUID)
        XCTAssertEqual(preferences.hotKey.display, "⌃⌥N")
        XCTAssertEqual(preferences.language, .english)
    }

    func testRoundTrip() throws {
        var preferences = Preferences()
        preferences.keyNotation = .openKey
        preferences.bpmThresholds = BPMThresholds(compatible: 4, stretch: 8)
        preferences.includeAdvancedRecommendations = true
        preferences.autoExpandOnTrackChange = false
        preferences.showSuggestions = false
        preferences.fallbackCapsuleWidth = 260
        preferences.preferredDisplayUUID = "37D8832A-2D66-02CA-B9F7-8F30A301B230"
        preferences.hotKey = HotKeyCombo(keyCode: 2, modifiers: HotKeyCombo.command | HotKeyCombo.shift, display: "⇧⌘D")
        preferences.language = .traditionalChinese
        let data = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: data), preferences)
    }

    func testMissingOrBadFieldsKeepTheirDefaults() throws {
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)), Preferences())
        let partial = try JSONDecoder().decode(
            Preferences.self,
            from: Data(#"{"keyNotation":"bogus","bpmCompatible":8,"hotKey":"not an object","language":"xx"}"#.utf8)
        )
        XCTAssertEqual(partial.keyNotation, .camelot)
        XCTAssertEqual(partial.language, .english)
        XCTAssertEqual(partial.bpmThresholds.compatible, 8)
        XCTAssertEqual(partial.hotKey, .default)
    }

    func testSanitizedClampsValues() {
        var preferences = Preferences()
        preferences.bpmThresholds = BPMThresholds(compatible: 0, stretch: 100)
        preferences.fallbackCapsuleWidth = 1000
        XCTAssertEqual(preferences.sanitized().bpmThresholds, BPMThresholds(compatible: 1, stretch: 30))
        XCTAssertEqual(preferences.sanitized().fallbackCapsuleWidth, 480)

        preferences.bpmThresholds = BPMThresholds(compatible: 8, stretch: 5)
        XCTAssertEqual(preferences.sanitized().bpmThresholds, BPMThresholds(compatible: 8, stretch: 8), "yellow never below green")

        preferences.bpmThresholds = BPMThresholds(compatible: .nan, stretch: 10)
        XCTAssertEqual(preferences.sanitized().bpmThresholds.compatible, 1)
    }

    func testHotKeysNeedARealModifier() {
        XCTAssertTrue(HotKeyCombo.default.isValid)
        XCTAssertFalse(HotKeyCombo(keyCode: 45, modifiers: 0, display: "N").isValid)
        XCTAssertFalse(HotKeyCombo(keyCode: 45, modifiers: HotKeyCombo.shift, display: "⇧N").isValid)

        var preferences = Preferences()
        preferences.hotKey = HotKeyCombo(keyCode: 45, modifiers: HotKeyCombo.shift, display: "⇧N")
        XCTAssertEqual(preferences.sanitized().hotKey, .default)
    }

    func testModifierSymbolsUseTheMacOSOrder() {
        let all = HotKeyCombo.command | HotKeyCombo.shift | HotKeyCombo.option | HotKeyCombo.control
        XCTAssertEqual(HotKeyCombo.symbols(for: all), "⌃⌥⇧⌘")
        XCTAssertEqual(HotKeyCombo.symbols(for: HotKeyCombo.command), "⌘")
    }
}
