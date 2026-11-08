import Domain
import Foundation
import Observation
import SwiftUI

/// The interface language picked in Settings: English unless changed, whatever the system language is.
/// Translations live in Localizable.xcstrings.
///
/// Text in views follows it through `.appLanguage()` on each window's root view. Strings built in code
/// (window titles, menu items, messages) go through `L10n.string`. Both are observed, so views redraw
/// when the language changes.
@MainActor
enum L10n {
    @Observable
    final class Current {
        var language = AppLanguage.english
    }

    private static let current = Current()

    static var language: AppLanguage {
        get { current.language }
        set { current.language = newValue }
    }

    static var locale: Locale { Locale(identifier: language.rawValue) }

    /// `resource` in the interface language, e.g. `L10n.string("Not running")`.
    /// (`String(localized:locale:)` would not do: its locale only formats the arguments.)
    static func string(_ resource: LocalizedStringResource) -> String {
        var resource = resource
        resource.locale = locale
        return String(localized: resource)
    }

    /// "1 track", "12 tracks".
    static func tracks(_ count: Int) -> String {
        string("\(count) tracks")
    }
}

extension View {
    /// Shows this view's text in the interface language. Apply to each window's root view.
    func appLanguage() -> some View {
        modifier(AppLanguageModifier())
    }
}

private struct AppLanguageModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.environment(\.locale, L10n.locale)
    }
}

extension KeyRelation {
    /// `label` in the interface language.
    @MainActor
    var localizedLabel: String {
        switch self {
        case .same: L10n.string("Same key")
        case .adjacent: L10n.string("Adjacent")
        case .relative: L10n.string("Relative")
        case .energyBoost: L10n.string("Energy boost")
        case .semitoneUp: L10n.string("Semitone up")
        case .diagonal: L10n.string("Diagonal")
        }
    }
}
