import AppKit
import Domain
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let controller: NotchController
    @State private var loginItem = LoginItem()

    var body: some View {
        let settings = controller.settings
        let preferences = settings.preferences
        Form {
            Section("Display") {
                Picker("Key notation", selection: settings.binding(\.keyNotation)) {
                    Text("Camelot (8A)").tag(KeyNotation.camelot)
                    Text("Open Key (1m)").tag(KeyNotation.openKey)
                    Text("Traditional (Am)").tag(KeyNotation.traditional)
                }
                Toggle("Show advanced recommendations (semitone up, diagonal)", isOn: settings.binding(\.includeAdvancedRecommendations))
                Toggle("Expand for 4 seconds on track change", isOn: settings.binding(\.autoExpandOnTrackChange))
                Toggle("Show “Suggested next” (library tracks that match key and BPM)", isOn: settings.binding(\.showSuggestions))
            }

            Section {
                Stepper(value: settings.binding(\.bpmThresholds.compatible), in: Preferences.thresholdRange, step: 0.5) {
                    LabeledContent("Green: mix as is", value: percent(preferences.bpmThresholds.compatible))
                }
                Stepper(value: settings.binding(\.bpmThresholds.stretch), in: Preferences.thresholdRange, step: 0.5) {
                    LabeledContent("Yellow: needs a big pitch change", value: percent(preferences.bpmThresholds.stretch))
                }
            } header: {
                Text("BPM compatibility")
            } footer: {
                Text("Anything past the yellow threshold is grey. Half / double time is taken into account (e.g. 70 ↔ 140).")
            }

            Section {
                Picker("Show on", selection: settings.binding(\.preferredDisplayUUID)) {
                    Text("Built-in display (default)").tag(String?.none)
                    ForEach(ScreenLocator.displays(), id: \.uuid) { display in
                        Text(display.name).tag(Optional(display.uuid))
                    }
                }
                LabeledContent("Capsule width on displays without a notch") {
                    HStack {
                        Slider(value: settings.binding(\.fallbackCapsuleWidth), in: Preferences.fallbackWidthRange, step: 10)
                            .frame(width: 160)
                        Text("\(Int(preferences.fallbackCapsuleWidth)) pt")
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            } header: {
                Text("Notch")
            } footer: {
                Text("On external displays and Macs without a notch, the panel appears as a capsule at the top centre of the screen.")
            }

            Section("Keyboard shortcut") {
                LabeledContent("Expand / collapse panel") {
                    HotKeyRecorder(controller: controller)
                }
            }

            Section("General") {
                Picker("Language", selection: settings.binding(\.language)) {
                    Text(verbatim: "English").tag(AppLanguage.english)
                    Text(verbatim: "繁體中文").tag(AppLanguage.traditionalChinese)
                }
                Toggle("Launch at login", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                if loginItem.needsApproval {
                    HStack {
                        Text("Allow Amaterasu under Login Items in System Settings.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open System Settings") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let error = loginItem.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
            }

            Section {
                LabeledContent("Status", value: StatusText.short(controller.model.seratoStatus))
                Text(StatusText.advice(controller.model.seratoStatus))
                    .foregroundStyle(.secondary)
                LabeledContent("Database", value: "~/Library/Application Support/Serato/Library/master.sqlite")
                Button("Check Again") { controller.recheckSerato() }
            } header: {
                Text("Serato")
            } footer: {
                Text("Amaterasu only reads Serato's database. It never changes it and never uploads anything.")
            }

            Section {
                Button("Restore All Defaults") { controller.resetSettings() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 720)
        .appLanguage()
        .onAppear {
            loginItem.refresh()
            controller.recheckSerato()
        }
    }

    private func percent(_ value: Double) -> String {
        String(format: "±%.1f%%", value)
    }
}

@MainActor
@Observable
final class LoginItem {
    private(set) var status = SMAppService.mainApp.status
    private(set) var errorMessage: String?

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = L10n.string("Couldn't change the login item: \(error.localizedDescription)")
        }
        refresh()
    }
}
