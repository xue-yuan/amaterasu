import AppKit
import SeratoDatabase

/// Keeps `status` up to date: re-checks when Serato launches or quits, and on request.
/// Never keeps a database connection open (see docs/serato-findings.md).
@MainActor
final class SeratoMonitor {
    private(set) var status: SeratoStatus = .notRunning
    var onChange: ((SeratoStatus) -> Void)?

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == SeratoLibrary.bundleIdentifier else { return }
                MainActor.assumeIsolated { self?.seratoLaunchedOrQuit() }
            }
        }
        recheck()
    }

    func recheck() {
        let bundleID = SeratoLibrary.bundleIdentifier
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        let current = SeratoEnvironment.check(isInstalled: installed, isRunning: running)
        guard current != status else { return }
        status = current
        onChange?(current)
    }

    private func seratoLaunchedOrQuit() {
        recheck()
        // Serato opens its library a moment after launching; look again once it has.
        for delay in [1.5, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.recheck() }
            }
        }
    }
}
