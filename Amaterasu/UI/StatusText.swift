import SeratoDatabase

/// User-facing wording for each Serato status.
@MainActor
enum StatusText {
    /// For the menu bar menu and Settings, e.g. "Serato: Not running".
    static func short(_ status: SeratoStatus) -> String {
        switch status {
        case .notInstalled: L10n.string("Not installed")
        case .databaseMissing: L10n.string("Library database not found")
        case .databaseUnreadable: L10n.string("Can't read database")
        case .notRunning: L10n.string("Not running")
        case .incompatible: L10n.string("Unsupported version")
        case .ready: L10n.string("Running")
        }
    }

    /// Shown in the expanded panel when no deck has a track.
    static func panelMessage(_ status: SeratoStatus) -> String {
        switch status {
        case .notInstalled: L10n.string("Serato DJ Pro not found")
        case .databaseMissing: L10n.string("Serato library not found")
        case .databaseUnreadable: L10n.string("Can't read the Serato database")
        case .notRunning: L10n.string("Waiting for Serato…")
        case .incompatible: L10n.string("This version of Serato isn't supported")
        case .ready: L10n.string("Waiting for a track to load…")
        }
    }

    /// What to do about it, for Settings.
    static func advice(_ status: SeratoStatus) -> String {
        switch status {
        case .notInstalled:
            L10n.string("Amaterasu needs Serato DJ Pro 4. Once Serato is installed and has been opened once, this updates automatically.")
        case .databaseMissing:
            L10n.string("Open Serato DJ Pro 4 once so it can create its library. Amaterasu doesn't support Serato 3 or earlier, or Serato DJ Lite.")
        case .databaseUnreadable(let reason):
            L10n.string("Can't read Serato's database (\(reason)). If Serato was just opened or updated, it may still be preparing its library: wait a moment, then click “Check Again”. If it still can't be read, check the file permissions, or add Amaterasu under System Settings › Privacy & Security › Full Disk Access.")
        case .notRunning:
            L10n.string("Once Serato DJ Pro is open, the panel shows the loaded tracks automatically. If Serato is already open but this still says Not running (for example, right after an update or a slow launch), click “Check Again”.")
        case .incompatible(let missing):
            L10n.string("Serato's database structure isn't what Amaterasu expects; Serato may have been updated. Missing: \(missing.joined(separator: ", ")). Please update Amaterasu.")
        case .ready:
            L10n.string("Serato is running and its database is readable.")
        }
    }
}

