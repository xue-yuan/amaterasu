import AppKit
import Domain
import SwiftUI

/// Shows the current hotkey; click it, then press a new combination (Esc cancels).
struct HotKeyRecorder: View {
    let controller: NotchController
    @State private var isRecording = false
    @State private var message: String?
    @State private var monitor: Any?

    var body: some View {
        let current = controller.settings.preferences.hotKey
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Button(isRecording ? L10n.string("Press a new shortcut…") : current.display) {
                    isRecording ? stopRecording() : startRecording()
                }
                .frame(minWidth: 150)
                Button("Default") { apply(.default) }
                    .disabled(current == .default)
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        message = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let consumed = MainActor.assumeIsolated { record(event) }
            return consumed ? nil : event
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    /// Returns whether the key press was used.
    private func record(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        defer { stopRecording() }
        if event.keyCode == 53 { return true } // Esc
        let combo = HotKeyFormatter.combo(from: event)
        guard combo.isValid else {
            message = L10n.string("Include ⌘, ⌃ or ⌥")
            return true
        }
        apply(combo)
        return true
    }

    private func apply(_ combo: HotKeyCombo) {
        message = controller.setHotKey(combo) ? nil : L10n.string("\(combo.display) is unavailable; another app may be using it")
    }
}

enum HotKeyFormatter {
    static func combo(from event: NSEvent) -> HotKeyCombo {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers = 0
        if flags.contains(.command) { modifiers |= HotKeyCombo.command }
        if flags.contains(.shift) { modifiers |= HotKeyCombo.shift }
        if flags.contains(.option) { modifiers |= HotKeyCombo.option }
        if flags.contains(.control) { modifiers |= HotKeyCombo.control }
        let keyCode = Int(event.keyCode)
        let key = specialKeys[keyCode] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
        return HotKeyCombo(keyCode: keyCode, modifiers: modifiers, display: HotKeyCombo.symbols(for: modifiers) + key)
    }

    private static let specialKeys: [Int: String] = [
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}
