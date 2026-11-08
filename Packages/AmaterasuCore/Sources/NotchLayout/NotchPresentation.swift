import Foundation

/// Decides whether the panel is expanded.
///
/// Pure and clock-free: callers pass `now` with every event, and schedule a timer for
/// `nextDeadline(after:)` so time-based transitions (hover delay, exit grace, track-change peek) happen.
///
/// Rules:
/// - Hover: expands once the pointer has stayed `hoverDelay`; after it leaves, stays for `exitGrace`.
/// - Track change: expands for `peekDuration` (if enabled); a hovering pointer keeps it open afterwards.
/// - Toggle (hotkey / menu): collapsed → pinned open until toggled again; expanded → collapses at once
///   and ignores the current hover until the pointer leaves.
public struct NotchPresentation: Equatable, Sendable {
    public struct Timing: Equatable, Sendable {
        public var hoverDelay: TimeInterval = 0.12
        public var exitGrace: TimeInterval = 0.35
        public var peekDuration: TimeInterval = 4

        public init() {}
    }

    public var timing: Timing
    public var autoExpandOnTrackChange = true

    private var hoverStartedAt: Date?
    private var hoverSuppressed = false
    private var exitGraceUntil: Date?
    private var peekUntil: Date?
    private var isPinned = false

    public init(timing: Timing = Timing()) {
        self.timing = timing
    }

    public func isExpanded(at now: Date) -> Bool {
        if isPinned { return true }
        if let start = hoverStartedAt, !hoverSuppressed, now.timeIntervalSince(start) >= timing.hoverDelay { return true }
        if let until = exitGraceUntil, now < until { return true }
        if let until = peekUntil, now < until { return true }
        return false
    }

    /// The next moment `isExpanded` may change on its own, if any.
    public func nextDeadline(after now: Date) -> Date? {
        var candidates: [Date] = []
        if let start = hoverStartedAt, !hoverSuppressed { candidates.append(start.addingTimeInterval(timing.hoverDelay)) }
        if let until = exitGraceUntil { candidates.append(until) }
        if let until = peekUntil { candidates.append(until) }
        return candidates.filter { $0 > now }.min()
    }

    public mutating func pointerEntered(at now: Date) {
        // Re-entering while still open (e.g. during the exit grace) must not close it for the hover delay.
        hoverStartedAt = isExpanded(at: now) ? now.addingTimeInterval(-timing.hoverDelay) : now
        exitGraceUntil = nil
    }

    public mutating func pointerExited(at now: Date) {
        let wasExpanded = isExpanded(at: now)
        hoverStartedAt = nil
        hoverSuppressed = false
        exitGraceUntil = wasExpanded ? now.addingTimeInterval(timing.exitGrace) : nil
    }

    public mutating func trackChanged(at now: Date) {
        guard autoExpandOnTrackChange else { return }
        peekUntil = now.addingTimeInterval(timing.peekDuration)
    }

    public mutating func toggle(at now: Date) {
        if isExpanded(at: now) {
            isPinned = false
            peekUntil = nil
            exitGraceUntil = nil
            if hoverStartedAt != nil { hoverSuppressed = true }
        } else {
            isPinned = true
            hoverSuppressed = false
        }
    }
}
