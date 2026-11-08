import Domain
import Foundation
import Observation
import SwiftUI

/// The user's preferences, persisted as JSON in UserDefaults. Every change is sanitised, saved and
/// reported through `onChange(old, new)`.
@MainActor
@Observable
final class AppSettings {
    private(set) var preferences: Preferences
    @ObservationIgnored var onChange: ((Preferences, Preferences) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults?
    private static let storageKey = "preferences"

    /// `defaults: nil` keeps everything in memory (snapshots, previews).
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(Preferences.self, from: data) {
            preferences = saved.sanitized()
        } else {
            preferences = Preferences()
        }
    }

    func update(_ change: (inout Preferences) -> Void) {
        var next = preferences
        change(&next)
        next = next.sanitized()
        guard next != preferences else { return }
        let previous = preferences
        preferences = next
        if let data = try? JSONEncoder().encode(next) {
            defaults?.set(data, forKey: Self.storageKey)
        }
        onChange?(previous, next)
    }

    func resetToDefaults() {
        update { $0 = Preferences() }
    }

    /// A SwiftUI binding to one preference.
    func binding<Value: Sendable>(_ keyPath: WritableKeyPath<Preferences, Value> & Sendable) -> Binding<Value> {
        Binding(
            get: { MainActor.assumeIsolated { self.preferences[keyPath: keyPath] } },
            set: { newValue in MainActor.assumeIsolated { self.update { $0[keyPath: keyPath] = newValue } } }
        )
    }
}
