import AppKit
import Domain
import Mock
import NotchLayout
import SeratoDatabase

/// Wires settings, the data provider, the Serato status, the expand / collapse rules and the panel together.
@MainActor
final class NotchController {
    let settings: AppSettings
    let model: NotchViewModel
    /// Serato by default; MockProvider in demo mode.
    private var provider: any DeckStateProvider
    private var updatesTask: Task<Void, Never>?
    private var panel: NotchPanelController?
    private var presentation = NotchPresentation()
    private var deadlineTimer: Timer?
    private var hotKey: GlobalHotKey?
    private var registeredHotKey: HotKeyCombo?
    private var hasReceivedDecks = false
    private let seratoMonitor = SeratoMonitor()
    private lazy var settingsWindow = SettingsWindowController(controller: self)
    private lazy var sessionWindow = SessionWindowController(notch: model)
    private var suggestionTask: Task<Void, Never>?
    private var lastSuggestionRequest: SuggestionRequest?

    init() {
        settings = AppSettings()
        model = NotchViewModel(settings: settings)
        model.isDemo = false
        provider = SeratoDatabaseProvider()
    }

    func start() {
        L10n.language = settings.preferences.language
        panel = NotchPanelController(model: model) { [weak self] inside in
            self?.pointerChanged(inside: inside)
        }
        presentation.autoExpandOnTrackChange = settings.preferences.autoExpandOnTrackChange
        if !register(settings.preferences.hotKey) {
            NSLog("Amaterasu: could not register the \(settings.preferences.hotKey.display) hotkey")
        }
        settings.onChange = { [weak self] old, new in
            self?.settingsChanged(from: old, to: new)
        }
        seratoMonitor.onChange = { [weak self] status in
            self?.seratoStatusChanged(status)
        }
        model.onMainDeckChange = { [weak self] in
            self?.refreshSuggestions()
        }
        observeSession(of: provider)
        seratoMonitor.start()
        seratoStatusChanged(seratoMonitor.status)
        connect(provider)
        #if DEBUG
        listenForDebugCommands()
        #endif
    }

    func stop() {
        provider.stop()
        updatesTask?.cancel()
    }

    func togglePanel() {
        presentation.toggle(at: Date())
        refresh()
    }

    func showSettings() {
        settingsWindow.show()
    }

    func showSessions() {
        sessionWindow.show()
    }

    func recheckSerato() {
        seratoMonitor.recheck()
    }

    func resetSettings() {
        settings.resetToDefaults()
    }

    /// For the hotkey recorder: switches to `combo` and saves it, or keeps the current hotkey if
    /// `combo` cannot be registered.
    func setHotKey(_ combo: HotKeyCombo) -> Bool {
        guard combo != registeredHotKey else { return true }
        let previous = registeredHotKey ?? settings.preferences.hotKey
        guard register(combo) else {
            register(previous)
            return false
        }
        settings.update { $0.hotKey = combo }
        return true
    }

    // MARK: Demo mode (MockProvider)

    func setDemoMode(_ enabled: Bool) {
        guard enabled != model.isDemo else { return }
        model.isDemo = enabled
        replaceProvider(with: enabled ? MockProvider(deckCount: model.mockDeckCount) : makeSeratoProvider())
    }

    func simulateTrackChange() {
        (provider as? MockProvider)?.advance()
    }

    func setMockDeckCount(_ count: Int) {
        guard count != model.mockDeckCount else { return }
        model.mockDeckCount = count
        if model.isDemo {
            replaceProvider(with: MockProvider(deckCount: count))
        }
    }

    // MARK: Private

    private func seratoStatusChanged(_ status: SeratoStatus) {
        model.seratoStatus = status
        // Read Serato's database only while it runs and is compatible.
        (provider as? SeratoDatabaseProvider)?.isSeratoRunning = status == .ready
    }

    private func makeSeratoProvider() -> SeratoDatabaseProvider {
        let provider = SeratoDatabaseProvider()
        observeSession(of: provider)
        provider.isSeratoRunning = model.seratoStatus == .ready
        return provider
    }

    private func observeSession(of provider: any DeckStateProvider) {
        (provider as? SeratoDatabaseProvider)?.onSessionChange = { [weak self] session in
            self?.model.session = session
            self?.refreshSuggestions()
        }
    }

    private func replaceProvider(with newProvider: any DeckStateProvider) {
        provider.stop()
        model.manualMainDeckID = nil
        model.suggestions = []
        model.suggestionsUnavailable = false
        lastSuggestionRequest = nil
        provider = newProvider
        connect(newProvider)
    }

    private struct SuggestionRequest: Equatable {
        let key: MusicalKey
        let bpm: Double?
        let thresholds: BPMThresholds
        let includeAdvanced: Bool
        let excluded: Set<Int64>
        let isDemo: Bool
    }

    /// Re-ranks "next track" suggestions when the main deck, the settings or tonight's tracks change.
    /// Serato's library is queried off the main thread; demo mode uses MockProvider's invented library.
    private func refreshSuggestions() {
        let preferences = settings.preferences
        guard preferences.showSuggestions, let main = model.mainDeck, let key = main.key else {
            suggestionTask?.cancel()
            lastSuggestionRequest = nil
            model.suggestions = []
            model.suggestionsUnavailable = false
            return
        }
        let request = SuggestionRequest(
            key: key,
            bpm: main.bpm,
            thresholds: preferences.bpmThresholds,
            includeAdvanced: preferences.includeAdvancedRecommendations,
            excluded: model.isDemo ? [] : model.session?.assetIDs ?? [],
            isDemo: model.isDemo
        )
        guard request != lastSuggestionRequest else { return }
        lastSuggestionRequest = request
        suggestionTask?.cancel()

        if request.isDemo {
            model.suggestions = TrackSuggester.suggest(
                from: MockProvider.library, mainKey: key, mainBPM: main.bpm,
                thresholds: request.thresholds, includeAdvanced: request.includeAdvanced
            )
            model.suggestionsUnavailable = false
            return
        }
        suggestionTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                try? LibrarySuggestions.fetch(
                    mainKey: request.key, mainBPM: request.bpm, thresholds: request.thresholds,
                    includeAdvanced: request.includeAdvanced, excluding: request.excluded
                )
            }.value
            guard !Task.isCancelled, let self, self.lastSuggestionRequest == request else { return }
            if let result {
                self.model.suggestions = result
                self.model.suggestionsUnavailable = false
            } else {
                // Could not read the library. Drop the previous main deck's suggestions rather than show them
                // as if they were for this one, and try again on the next change.
                self.model.suggestions = []
                self.model.suggestionsUnavailable = true
                self.lastSuggestionRequest = nil
            }
        }
    }

    private func settingsChanged(from old: Preferences, to new: Preferences) {
        if new.language != old.language {
            L10n.language = new.language
            settingsWindow.languageDidChange()
            sessionWindow.languageDidChange()
        }
        presentation.autoExpandOnTrackChange = new.autoExpandOnTrackChange
        if new.hotKey != registeredHotKey, !register(new.hotKey) {
            if register(old.hotKey) {
                // Re-enters this method with the old hotkey already registered, so it stops there.
                settings.update { $0.hotKey = old.hotKey }
            } else {
                // Reverting the setting would bounce between two hotkeys that both fail, forever. Keep the
                // setting; it is retried on the next settings change.
                NSLog("Amaterasu: could not register \(new.hotKey.display) or \(old.hotKey.display)")
            }
        }
        if new.preferredDisplayUUID != old.preferredDisplayUUID || new.fallbackCapsuleWidth != old.fallbackCapsuleWidth {
            panel?.updateGeometry()
        }
        if new.showSuggestions != old.showSuggestions {
            panel?.contentDidChange()
        }
        refreshSuggestions()
        refresh()
    }

    @discardableResult
    private func register(_ combo: HotKeyCombo) -> Bool {
        hotKey?.invalidate()
        hotKey = GlobalHotKey(keyCode: combo.keyCode, modifiers: combo.modifiers) { [weak self] in
            self?.togglePanel()
        }
        registeredHotKey = hotKey == nil ? nil : combo
        return hotKey != nil
    }

    private func connect(_ provider: any DeckStateProvider) {
        updatesTask?.cancel()
        hasReceivedDecks = false
        let updates = provider.updates
        updatesTask = Task { [weak self] in
            for await decks in updates {
                self?.receive(decks)
            }
        }
        Task { try? await provider.start() }
    }

    private func receive(_ decks: [DeckState]) {
        let changed = TrackChanges.changedDecks(from: model.decks, to: decks)
        model.decks = decks
        if let manual = model.manualMainDeckID, !decks.contains(where: { $0.id == manual }) {
            model.manualMainDeckID = nil
        }
        // The first value is the initial state, not a track change.
        if hasReceivedDecks, !changed.isEmpty {
            presentation.trackChanged(at: Date())
        }
        hasReceivedDecks = true
        panel?.contentDidChange()
        refreshSuggestions()
        refresh()
    }

    private func pointerChanged(inside: Bool) {
        if inside {
            presentation.pointerEntered(at: Date())
        } else {
            presentation.pointerExited(at: Date())
        }
        refresh()
    }

    /// Applies the current expand / collapse decision and schedules the next time-based transition.
    private func refresh() {
        let now = Date()
        panel?.setExpanded(presentation.isExpanded(at: now))
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        if let deadline = presentation.nextDeadline(after: now) {
            deadlineTimer = Timer.scheduledTimer(withTimeInterval: max(deadline.timeIntervalSinceNow, 0.01), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    #if DEBUG
    /// Debug builds only: lets scripts drive the app by posting the distributed notification
    /// `local.amaterasu.debug` with object "toggle", "advance", "decks:4", "settings", "language:zh-Hant",
    /// "settings-snapshot:<png path>" or "status:<text file path>".
    private func listenForDebugCommands() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("local.amaterasu.debug"), object: nil, queue: .main
        ) { [weak self] notification in
            let command = notification.object as? String ?? ""
            MainActor.assumeIsolated {
                guard let self else { return }
                switch command {
                case "toggle": self.togglePanel()
                case "advance": self.simulateTrackChange()
                case "settings": self.showSettings()
                case let c where c.hasPrefix("sessions-snapshot:"):
                    // "sessions-snapshot:<png path>" or "sessions-snapshot:<session id>:<png path>"
                    let argument = String(c.dropFirst(18))
                    let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
                    if parts.count == 2, let id = Int64(parts[0]) {
                        self.sessionWindow.snapshot(to: URL(fileURLWithPath: parts[1]), session: id)
                    } else {
                        self.sessionWindow.snapshot(to: URL(fileURLWithPath: argument))
                    }
                case let c where c.hasPrefix("language:"):
                    if let language = AppLanguage(rawValue: String(c.dropFirst(9))) {
                        self.settings.update { $0.language = language }
                    }
                case let c where c.hasPrefix("decks:"):
                    self.setMockDeckCount(Int(c.dropFirst(6)) ?? 2)
                case let c where c.hasPrefix("settings-snapshot:"):
                    self.settingsWindow.snapshot(to: URL(fileURLWithPath: String(c.dropFirst(18))))
                case let c where c.hasPrefix("status:"):
                    self.seratoMonitor.recheck()
                    let decks = self.model.decks.map { "D\($0.id) \($0.title ?? "—") \($0.key?.camelot ?? "—") \($0.bpm.map { String($0) } ?? "—") started=\($0.hasStartedPlaying) earlier=\($0.playedEarlierAt != nil)" }
                    let suggestions = self.model.suggestions.map { "\($0.track.key?.camelot ?? "—") \($0.track.bpm.map { String($0) } ?? "—") \($0.relation.label) \($0.track.artist ?? "") - \($0.track.title ?? "")" }
                    let text = """
                        status: \(self.seratoMonitor.status)
                        main: \(self.model.mainDeckID.map(String.init) ?? "—")
                        decks:\n  \(decks.joined(separator: "\n  "))
                        suggestions:\n  \(suggestions.joined(separator: "\n  "))
                        session: \(self.model.session.map { "\($0.name) open=\($0.isOpen) tracks=\($0.tracks.count) assets=\($0.assetIDs.count)" } ?? "none")
                        \(self.settings.preferences)

                        """
                    try? text.write(toFile: String(c.dropFirst(7)), atomically: true, encoding: .utf8)
                default:
                    NSLog("Amaterasu: unknown debug command \(command)")
                }
            }
        }
    }
    #endif
}
