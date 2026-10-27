import SwiftUI
import AppKit
import AuthenticatorCore

// MARK: - Low-frequency, pausable timeline schedule

/// Drives the live codes and countdown rings.
///
/// Replaces `TimelineView(.animation(...))` / `.periodic(by: 0.5)`, which kept every
/// row redrawing many times a second — even while the window was hidden, minimised or
/// the (always-alive) menu bar panel was closed.
///
/// * `.everySecond` ticks once per second, aligned to whole wall-clock seconds.
/// * `.codeChanges(period:)` ticks only when the code changes (period rollover) and
///   when it enters its last 5 seconds (red "expiring" colour).
/// * When `isPaused` is true the schedule yields a single entry and then stops, so the
///   timeline costs nothing until it becomes visible again (it then redraws at once).
struct CodeTimelineSchedule: TimelineSchedule {
    enum Cadence: Equatable {
        case everySecond
        case codeChanges(period: Int)
    }

    /// Seconds before rollover at which a code is shown as "expiring".
    static let expiringThreshold: Double = 5

    var cadence: Cadence
    var isPaused: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        if isPaused {
            var delivered = false
            return AnyIterator {
                guard !delivered else { return nil }
                delivered = true
                return startDate
            }
        }

        switch cadence {
        case .everySecond:
            var next: Date? = startDate
            return AnyIterator {
                guard let current = next else { return nil }
                let following = (current.timeIntervalSince1970 + 1).rounded(.down)
                next = Date(timeIntervalSince1970: following)
                return current
            }

        case .codeChanges(let rawPeriod):
            let period = Double(max(rawPeriod, 1))
            let warn = min(Self.expiringThreshold, period)
            var next: Date? = startDate
            return AnyIterator {
                guard let current = next else { return nil }
                let t = current.timeIntervalSince1970
                let boundary = ((t / period).rounded(.down) + 1) * period
                let warning = boundary - warn
                // Next key moment strictly after `t`: the "expiring" point or the rollover.
                next = Date(timeIntervalSince1970: warning > t ? warning : boundary)
                return current
            }
        }
    }
}

// MARK: - Code cache

/// Caches each account's current code so HMAC is computed once per period per account,
/// not on every redraw.
@MainActor
enum CodeCache {
    private struct Entry {
        let account: OTPAccount
        let counter: UInt64
        let code: String
    }

    private static var entries: [UUID: Entry] = [:]

    static func code(for account: OTPAccount, at date: Date) -> String {
        let counter = OTP.counter(at: date, period: account.period)
        if let entry = entries[account.id], entry.counter == counter, entry.account == account {
            return entry.code
        }
        let code = account.code(at: date)
        if entries.count > 512 { entries.removeAll(keepingCapacity: true) }
        entries[account.id] = Entry(account: account, counter: counter, code: code)
        return code
    }
}

// MARK: - Pausing while hidden

private struct CodesPausedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when the window showing the codes is not visible (closed menu bar panel,
    /// minimised, fully covered, on another Space, app hidden, display asleep).
    var codesPaused: Bool {
        get { self[CodesPausedKey.self] }
        set { self[CodesPausedKey.self] = newValue }
    }
}

extension View {
    /// Pauses the live codes/countdowns inside this view while its window isn't visible.
    func pausesCodesWhenHidden() -> some View {
        modifier(PauseCodesWhenHiddenModifier())
    }
}

private struct PauseCodesWhenHiddenModifier: ViewModifier {
    @State private var windowVisible = true

    func body(content: Content) -> some View {
        content
            .environment(\.codesPaused, !windowVisible)
            .background(WindowVisibilityReader(isVisible: $windowVisible))
    }
}

/// Reports whether the hosting NSWindow is actually visible on screen, using
/// `NSWindow.occlusionState` (covers minimised, occluded, ordered-out, hidden app,
/// other Space and display sleep).
private struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> VisibilityTrackingView {
        let view = VisibilityTrackingView()
        view.onChange = { visible in isVisible = visible }
        return view
    }

    func updateNSView(_ nsView: VisibilityTrackingView, context: Context) {
        nsView.onChange = { visible in isVisible = visible }
    }

    final class VisibilityTrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var lastReported: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObservers()
            guard let window else {
                report(false)
                return
            }
            let center = NotificationCenter.default
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
            ]
            for name in names {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reportCurrentState() }
                })
            }
            reportCurrentState()
        }

        private func removeObservers() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
        }

        private func reportCurrentState() {
            guard let window else {
                report(false)
                return
            }
            report(window.occlusionState.contains(.visible) && !window.isMiniaturized)
        }

        private func report(_ visible: Bool) {
            guard visible != lastReported else { return }
            lastReported = visible
            // Defer: never mutate SwiftUI state during a view update.
            DispatchQueue.main.async { [weak self] in
                self?.onChange?(visible)
            }
        }
    }
}
