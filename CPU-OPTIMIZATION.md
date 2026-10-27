# CPU optimisation (idle CPU usage)

Version edited: `/workspace/authenticator-mac` (SwiftPM, commit 6f05dcc, 21 Oct 2026 23:37 +0200). It is newer than
`/workspace/authenticator` (2bfa6bd, 22:59) and is a superset of it: menu bar extra, lock, settings and camera scanning.
No Swift toolchain on the box, so this was reviewed by eye only and **not compiled**.

## Root causes
1. **`LiveCountdown` used `TimelineView(.animation(minimumInterval: 1/15))`**: a 15 fps redraw loop **per account row**, running forever.
2. **The `MenuBarExtra(.window)` panel keeps its SwiftUI hierarchy alive after it closes**, and the menu bar extra is on by default.
   So every account had a second set of 15 fps timelines ticking while nothing was on screen. The same happened in the main window
   when it was minimised, covered, on another Space, or hidden.
3. **`LiveCode` used `.periodic(by: 0.5)` and recomputed the HMAC-based TOTP (pure-Swift SHA) on every tick**, about 2× per second per row in each surface,
   although the code only changes once every 30 s.
4. Camera: Vision kept analysing frames while a detected code was waiting for a decision. The async permission callback could also start the
   `AVCaptureSession` after the scan sheet had already closed, leaving it running.

## Changes
- New `Sources/Authenticator/CodeTimeline.swift`:
  - `CodeTimelineSchedule`: a custom `TimelineSchedule`. `.everySecond` ticks once per second on whole wall-clock seconds and drives the ring and number.
    `.codeChanges(period:)` ticks only at rollover and at the 5 s "expiring" point. When paused it yields a single entry, so the timeline is idle.
  - `CodeCache`: computes each code once per period per account. The cache key is the account plus its time counter, so edits invalidate it.
  - `.pausesCodesWhenHidden()`: reads `NSWindow.occlusionState` and minimise notifications, then sets `\.codesPaused` in the environment.
    It is applied to `ContentView` and `MenuBarView`. Codes redraw as soon as the window is visible again. The codes are **not** paused when the app is merely inactive,
    so a code stays correct while you type it into a browser next to the window.
- `AccountRow.swift`: `LiveCode` and `LiveCountdown` now use the schedules above.
- `CameraScanner.swift`: Vision is skipped while a payload is pending. A `wantsRunning` guard covers the permission callback. `deinit` stops the session.

Visible difference: the countdown ring now moves in 1-second steps instead of sweeping at 15 fps. Colours, layout, the expiring-red state
and the numeric code transition are unchanged.

## Rebuild / run on the Mac
```
cd authenticator-mac
swift build -c release && swift run -c release Authenticator   # or open Package.swift in Xcode and Run
swift test                                                       # core tests
```
Check with Activity Monitor / Mole: the app should stay at about 0 % CPU while the window and menu bar panel are closed, and use only a small amount while visible.

## Unified diff
```diff
diff --git a/Sources/Authenticator/AccountRow.swift b/Sources/Authenticator/AccountRow.swift
index 2fcdfab..6321454 100644
--- a/Sources/Authenticator/AccountRow.swift
+++ b/Sources/Authenticator/AccountRow.swift
@@ -63,11 +63,14 @@ struct AccountRow: View {
 struct LiveCode: View {
     let account: OTPAccount
     var size: CGFloat = 30
+    @Environment(\.codesPaused) private var paused
 
     var body: some View {
-        TimelineView(.periodic(from: .now, by: 0.5)) { context in
-            let code = account.code(at: context.date)
-            let expiring = account.secondsRemaining(at: context.date) <= 5
+        // Redraws only when the code changes or enters its last 5 s (not every 0.5 s),
+        // and not at all while the window is hidden. The code itself is cached per period.
+        TimelineView(CodeTimelineSchedule(cadence: .codeChanges(period: account.period), isPaused: paused)) { context in
+            let code = CodeCache.code(for: account, at: context.date)
+            let expiring = account.secondsRemaining(at: context.date) <= CodeTimelineSchedule.expiringThreshold
             Text(OTP.formatted(code))
                 .font(.system(size: size, weight: .medium, design: .monospaced))
                 .foregroundStyle(expiring ? Color.red : Color.accentColor)
@@ -82,9 +85,12 @@ struct LiveCode: View {
 struct LiveCountdown: View {
     let account: OTPAccount
     var diameter: CGFloat = 30
+    @Environment(\.codesPaused) private var paused
 
     var body: some View {
-        TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { context in
+        // Once per second (aligned to whole seconds) instead of a 15 fps animation
+        // timeline per row; paused entirely while the window isn't visible.
+        TimelineView(CodeTimelineSchedule(cadence: .everySecond, isPaused: paused)) { context in
             CountdownRing(remaining: account.secondsRemaining(at: context.date), period: account.period, diameter: diameter)
         }
     }
diff --git a/Sources/Authenticator/CameraScanner.swift b/Sources/Authenticator/CameraScanner.swift
index fb06302..ddbc022 100644
--- a/Sources/Authenticator/CameraScanner.swift
+++ b/Sources/Authenticator/CameraScanner.swift
@@ -22,15 +22,26 @@ final class CameraScanner: NSObject, ObservableObject, AVCaptureVideoDataOutputS
     private let queue = DispatchQueue(label: "com.baiehclaca.authenticator.camera")
     private var lastAnalysis = Date.distantPast // accessed on `queue` only
     private var isConfigured = false             // accessed on `queue` only
+    /// True while a detected payload awaits a decision; frames are skipped meanwhile.
+    private var hasPendingPayload = false        // accessed on `queue` only
+    /// Whether the scan view still wants the camera (main thread only). Guards the
+    /// async permission callback from starting the camera after the sheet closed.
+    private var wantsRunning = false
 
     func start() {
+        wantsRunning = true
         switch AVCaptureDevice.authorizationStatus(for: .video) {
         case .authorized:
             configureAndRun()
         case .notDetermined:
             AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                 DispatchQueue.main.async {
-                    if granted { self?.configureAndRun() } else { self?.state = .denied }
+                    guard let self else { return }
+                    if !granted {
+                        self.state = .denied
+                    } else if self.wantsRunning {
+                        self.configureAndRun()
+                    }
                 }
             }
         default:
@@ -39,6 +50,7 @@ final class CameraScanner: NSObject, ObservableObject, AVCaptureVideoDataOutputS
     }
 
     func stop() {
+        wantsRunning = false
         queue.async { [session] in
             if session.isRunning { session.stopRunning() }
         }
@@ -47,6 +59,15 @@ final class CameraScanner: NSObject, ObservableObject, AVCaptureVideoDataOutputS
     /// Resume scanning after a payload was rejected.
     func resume() {
         detectedPayload = nil
+        queue.async { [weak self] in self?.hasPendingPayload = false }
+    }
+
+    deinit {
+        // Never leave the camera (and its green light) running once the scanner is gone.
+        let session = self.session
+        queue.async {
+            if session.isRunning { session.stopRunning() }
+        }
     }
 
     private func configureAndRun() {
@@ -97,6 +118,8 @@ final class CameraScanner: NSObject, ObservableObject, AVCaptureVideoDataOutputS
 
     func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                        from connection: AVCaptureConnection) {
+        // Don't run Vision while a found code is waiting to be accepted/rejected.
+        guard !hasPendingPayload else { return }
         let now = Date()
         guard now.timeIntervalSince(lastAnalysis) > 0.15 else { return }
         lastAnalysis = now
@@ -110,6 +133,7 @@ final class CameraScanner: NSObject, ObservableObject, AVCaptureVideoDataOutputS
             .compactMap { $0.payloadStringValue }
             .first { $0.lowercased().hasPrefix("otpauth") }
         guard let payload else { return }
+        hasPendingPayload = true
         DispatchQueue.main.async { [weak self] in
             guard let self, self.detectedPayload == nil else { return }
             self.detectedPayload = payload
diff --git a/Sources/Authenticator/ContentView.swift b/Sources/Authenticator/ContentView.swift
index bf359fe..429c2d2 100644
--- a/Sources/Authenticator/ContentView.swift
+++ b/Sources/Authenticator/ContentView.swift
@@ -57,6 +57,7 @@ struct ContentView: View {
         }
         .overlay(alignment: .bottom) { bannerView }
         .animation(.easeInOut(duration: 0.2), value: model.banner)
+        .pausesCodesWhenHidden()
     }
 
     // MARK: - List
diff --git a/Sources/Authenticator/MenuBarView.swift b/Sources/Authenticator/MenuBarView.swift
index f74d9ad..3af1d61 100644
--- a/Sources/Authenticator/MenuBarView.swift
+++ b/Sources/Authenticator/MenuBarView.swift
@@ -56,6 +56,8 @@ struct MenuBarView: View {
             .padding(10)
         }
         .frame(width: 320)
+        // The menu bar panel stays alive after it closes; stop the codes ticking then.
+        .pausesCodesWhenHidden()
     }
 }
 
diff --git a/Sources/Authenticator/CodeTimeline.swift b/Sources/Authenticator/CodeTimeline.swift
new file mode 100644
index 0000000..6ae944d
--- /dev/null
+++ b/Sources/Authenticator/CodeTimeline.swift
@@ -0,0 +1,189 @@
+import SwiftUI
+import AppKit
+import AuthenticatorCore
+
+// MARK: - Low-frequency, pausable timeline schedule
+
+/// Drives the live codes and countdown rings.
+///
+/// Replaces `TimelineView(.animation(...))` / `.periodic(by: 0.5)`, which kept every
+/// row redrawing many times a second — even while the window was hidden, minimised or
+/// the (always-alive) menu bar panel was closed.
+///
+/// * `.everySecond` ticks once per second, aligned to whole wall-clock seconds.
+/// * `.codeChanges(period:)` ticks only when the code changes (period rollover) and
+///   when it enters its last 5 seconds (red "expiring" colour).
+/// * When `isPaused` is true the schedule yields a single entry and then stops, so the
+///   timeline costs nothing until it becomes visible again (it then redraws at once).
+struct CodeTimelineSchedule: TimelineSchedule {
+    enum Cadence: Equatable {
+        case everySecond
+        case codeChanges(period: Int)
+    }
+
+    /// Seconds before rollover at which a code is shown as "expiring".
+    static let expiringThreshold: Double = 5
+
+    var cadence: Cadence
+    var isPaused: Bool
+
+    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
+        if isPaused {
+            var delivered = false
+            return AnyIterator {
+                guard !delivered else { return nil }
+                delivered = true
+                return startDate
+            }
+        }
+
+        switch cadence {
+        case .everySecond:
+            var next: Date? = startDate
+            return AnyIterator {
+                guard let current = next else { return nil }
+                let following = (current.timeIntervalSince1970 + 1).rounded(.down)
+                next = Date(timeIntervalSince1970: following)
+                return current
+            }
+
+        case .codeChanges(let rawPeriod):
+            let period = Double(max(rawPeriod, 1))
+            let warn = min(Self.expiringThreshold, period)
+            var next: Date? = startDate
+            return AnyIterator {
+                guard let current = next else { return nil }
+                let t = current.timeIntervalSince1970
+                let boundary = ((t / period).rounded(.down) + 1) * period
+                let warning = boundary - warn
+                // Next key moment strictly after `t`: the "expiring" point or the rollover.
+                next = Date(timeIntervalSince1970: warning > t ? warning : boundary)
+                return current
+            }
+        }
+    }
+}
+
+// MARK: - Code cache
+
+/// Caches each account's current code so HMAC is computed once per period per account,
+/// not on every redraw.
+@MainActor
+enum CodeCache {
+    private struct Entry {
+        let account: OTPAccount
+        let counter: UInt64
+        let code: String
+    }
+
+    private static var entries: [UUID: Entry] = [:]
+
+    static func code(for account: OTPAccount, at date: Date) -> String {
+        let counter = OTP.counter(at: date, period: account.period)
+        if let entry = entries[account.id], entry.counter == counter, entry.account == account {
+            return entry.code
+        }
+        let code = account.code(at: date)
+        if entries.count > 512 { entries.removeAll(keepingCapacity: true) }
+        entries[account.id] = Entry(account: account, counter: counter, code: code)
+        return code
+    }
+}
+
+// MARK: - Pausing while hidden
+
+private struct CodesPausedKey: EnvironmentKey {
+    static let defaultValue = false
+}
+
+extension EnvironmentValues {
+    /// True when the window showing the codes is not visible (closed menu bar panel,
+    /// minimised, fully covered, on another Space, app hidden, display asleep).
+    var codesPaused: Bool {
+        get { self[CodesPausedKey.self] }
+        set { self[CodesPausedKey.self] = newValue }
+    }
+}
+
+extension View {
+    /// Pauses the live codes/countdowns inside this view while its window isn't visible.
+    func pausesCodesWhenHidden() -> some View {
+        modifier(PauseCodesWhenHiddenModifier())
+    }
+}
+
+private struct PauseCodesWhenHiddenModifier: ViewModifier {
+    @State private var windowVisible = true
+
+    func body(content: Content) -> some View {
+        content
+            .environment(\.codesPaused, !windowVisible)
+            .background(WindowVisibilityReader(isVisible: $windowVisible))
+    }
+}
+
+/// Reports whether the hosting NSWindow is actually visible on screen, using
+/// `NSWindow.occlusionState` (covers minimised, occluded, ordered-out, hidden app,
+/// other Space and display sleep).
+private struct WindowVisibilityReader: NSViewRepresentable {
+    @Binding var isVisible: Bool
+
+    func makeNSView(context: Context) -> VisibilityTrackingView {
+        let view = VisibilityTrackingView()
+        view.onChange = { visible in isVisible = visible }
+        return view
+    }
+
+    func updateNSView(_ nsView: VisibilityTrackingView, context: Context) {
+        nsView.onChange = { visible in isVisible = visible }
+    }
+
+    final class VisibilityTrackingView: NSView {
+        var onChange: ((Bool) -> Void)?
+        private var observers: [NSObjectProtocol] = []
+        private var lastReported: Bool?
+
+        override func viewDidMoveToWindow() {
+            super.viewDidMoveToWindow()
+            removeObservers()
+            guard let window else {
+                report(false)
+                return
+            }
+            let center = NotificationCenter.default
+            let names: [Notification.Name] = [
+                NSWindow.didChangeOcclusionStateNotification,
+                NSWindow.didMiniaturizeNotification,
+                NSWindow.didDeminiaturizeNotification,
+            ]
+            for name in names {
+                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
+                    MainActor.assumeIsolated { self?.reportCurrentState() }
+                })
+            }
+            reportCurrentState()
+        }
+
+        private func removeObservers() {
+            for observer in observers { NotificationCenter.default.removeObserver(observer) }
+            observers.removeAll()
+        }
+
+        private func reportCurrentState() {
+            guard let window else {
+                report(false)
+                return
+            }
+            report(window.occlusionState.contains(.visible) && !window.isMiniaturized)
+        }
+
+        private func report(_ visible: Bool) {
+            guard visible != lastReported else { return }
+            lastReported = visible
+            // Defer: never mutate SwiftUI state during a view update.
+            DispatchQueue.main.async { [weak self] in
+                self?.onChange?(visible)
+            }
+        }
+    }
+}
```
