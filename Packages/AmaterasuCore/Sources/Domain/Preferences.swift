import Foundation

/// A global hotkey: a virtual key code plus Carbon modifier flags, kept free of AppKit / Carbon types.
public struct HotKeyCombo: Codable, Equatable, Sendable {
    // Carbon modifier flags (cmdKey, shiftKey, optionKey, controlKey).
    public static let command = 0x0100
    public static let shift = 0x0200
    public static let option = 0x0800
    public static let control = 0x1000

    public var keyCode: Int
    public var modifiers: Int
    /// What the user sees, e.g. `⌃⌥N`.
    public var display: String

    public init(keyCode: Int, modifiers: Int, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    /// ⌃⌥N (kVK_ANSI_N = 45).
    public static let `default` = HotKeyCombo(keyCode: 45, modifiers: control | option, display: "⌃⌥N")

    /// Needs ⌘, ⌃ or ⌥: a bare key, or ⇧ + key, would fire while typing.
    public var isValid: Bool {
        modifiers & (Self.command | Self.control | Self.option) != 0
    }

    /// Modifier symbols in the standard macOS order, e.g. `⌃⌥⇧⌘`.
    public static func symbols(for modifiers: Int) -> String {
        var symbols = ""
        if modifiers & control != 0 { symbols += "⌃" }
        if modifiers & option != 0 { symbols += "⌥" }
        if modifiers & shift != 0 { symbols += "⇧" }
        if modifiers & command != 0 { symbols += "⌘" }
        return symbols
    }
}

/// The language the interface is shown in.
public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case english = "en"
    case traditionalChinese = "zh-Hant"
}

/// Everything the user can change in Settings. Pure value; the app persists it.
public struct Preferences: Equatable, Sendable {
    public var keyNotation: KeyNotation = .camelot
    public var bpmThresholds = BPMThresholds()
    public var includeAdvancedRecommendations = false
    public var autoExpandOnTrackChange = true
    /// Show "next track" suggestions from the Serato library in the expanded panel.
    public var showSuggestions = true
    /// Width of the capsule on screens without a notch.
    public var fallbackCapsuleWidth: Double = 200
    /// The display to show the panel on (its CGDisplay UUID); nil = the built-in display.
    public var preferredDisplayUUID: String?
    public var hotKey = HotKeyCombo.default
    /// English unless the user picks another language, whatever the system language is.
    public var language = AppLanguage.english

    public init() {}

    public static let thresholdRange: ClosedRange<Double> = 1...30
    public static let fallbackWidthRange: ClosedRange<Double> = 140...480

    /// Values brought into range: thresholds within 1–30 % with yellow never below green, capsule width
    /// within 140–480 pt, and an unusable hotkey replaced by the default.
    public func sanitized() -> Preferences {
        var clean = self
        clean.bpmThresholds.compatible = Self.clamp(clean.bpmThresholds.compatible, to: Self.thresholdRange)
        clean.bpmThresholds.stretch = max(
            Self.clamp(clean.bpmThresholds.stretch, to: Self.thresholdRange),
            clean.bpmThresholds.compatible
        )
        clean.fallbackCapsuleWidth = Self.clamp(clean.fallbackCapsuleWidth, to: Self.fallbackWidthRange)
        if !clean.hotKey.isValid { clean.hotKey = .default }
        return clean
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

extension Preferences: Codable {
    private enum CodingKeys: String, CodingKey {
        case keyNotation, bpmCompatible, bpmStretch, includeAdvancedRecommendations
        case autoExpandOnTrackChange, showSuggestions, fallbackCapsuleWidth, preferredDisplayUUID, hotKey
        case language
    }

    /// Missing or unreadable fields keep their defaults, so settings saved by another version still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var preferences = Preferences()
        if let value = try? container.decodeIfPresent(KeyNotation.self, forKey: .keyNotation) {
            preferences.keyNotation = value
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: .bpmCompatible) {
            preferences.bpmThresholds.compatible = value
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: .bpmStretch) {
            preferences.bpmThresholds.stretch = value
        }
        if let value = try? container.decodeIfPresent(Bool.self, forKey: .includeAdvancedRecommendations) {
            preferences.includeAdvancedRecommendations = value
        }
        if let value = try? container.decodeIfPresent(Bool.self, forKey: .autoExpandOnTrackChange) {
            preferences.autoExpandOnTrackChange = value
        }
        if let value = try? container.decodeIfPresent(Bool.self, forKey: .showSuggestions) {
            preferences.showSuggestions = value
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: .fallbackCapsuleWidth) {
            preferences.fallbackCapsuleWidth = value
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: .preferredDisplayUUID) {
            preferences.preferredDisplayUUID = value
        }
        if let value = try? container.decodeIfPresent(HotKeyCombo.self, forKey: .hotKey) {
            preferences.hotKey = value
        }
        if let value = try? container.decodeIfPresent(AppLanguage.self, forKey: .language) {
            preferences.language = value
        }
        self = preferences
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyNotation, forKey: .keyNotation)
        try container.encode(bpmThresholds.compatible, forKey: .bpmCompatible)
        try container.encode(bpmThresholds.stretch, forKey: .bpmStretch)
        try container.encode(includeAdvancedRecommendations, forKey: .includeAdvancedRecommendations)
        try container.encode(autoExpandOnTrackChange, forKey: .autoExpandOnTrackChange)
        try container.encode(showSuggestions, forKey: .showSuggestions)
        try container.encode(fallbackCapsuleWidth, forKey: .fallbackCapsuleWidth)
        try container.encodeIfPresent(preferredDisplayUUID, forKey: .preferredDisplayUUID)
        try container.encode(hotKey, forKey: .hotKey)
        try container.encode(language, forKey: .language)
    }
}
