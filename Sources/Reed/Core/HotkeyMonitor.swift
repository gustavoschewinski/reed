import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let dictate = Self("dictate")
}

extension Notification.Name {
    /// Posted when the user records a new dictation shortcut.
    ///
    /// KeyboardShortcuts posts its own equivalent, but keeps that name
    /// `internal`, so this is Reed's. `SettingsView` — the only place a
    /// shortcut can be changed — posts it from the recorder's `onChange`,
    /// and the sidebar's status footer listens, so the two stay in
    /// agreement while both are on screen at once.
    static let reedShortcutDidChange = Notification.Name("reed.shortcutDidChange")
}

enum HotkeyGesture: Sendable, Equatable {
    /// Quick press and release — toggle recording on or off.
    case tap
    /// Held past the threshold — start push-to-talk.
    case holdStart
    /// Released after a hold — stop push-to-talk.
    case holdEnd
}

/// Decides whether a press is a tap or a hold. Pure: it sees only timestamps in
/// seconds, from any monotonic source.
struct HotkeyInterpreter: Sendable {
    /// Single source of truth for the tap/hold boundary. `HotkeyMonitor` sleeps
    /// for exactly this long before polling `elapsedCheck`; the two must never
    /// diverge. If the monitor's sleep were shorter than this threshold, its
    /// one-shot poll would fire too early, see `elapsedCheck` return nil, and
    /// never retry — so `.holdStart` would never fire during a hold, even
    /// though `.holdEnd` still would (it recomputes from real elapsed time on
    /// release). Binding both to this constant makes that divergence
    /// impossible instead of merely unlikely.
    static let holdThreshold: Duration = .milliseconds(400)

    private let holdThreshold: Double
    private var pressedAt: Double?
    private var holding = false

    init(holdThreshold: Duration = Self.holdThreshold) {
        let c = holdThreshold.components
        self.holdThreshold = Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    /// `mode` defaults to `.automatic` so every call site (and every test)
    /// written before `DictationMode` existed keeps meaning exactly what it
    /// said — this is additive, not a replacement of the original state
    /// machine below.
    mutating func keyDown(at time: Double, mode: DictationMode = .automatic) -> HotkeyGesture? {
        switch mode {
        case .toggle:
            // The press itself is the whole gesture — .tap is what
            // `AppDelegate` already maps to `session.toggle()`, so reusing
            // it here needs no new gesture case. There is nothing to time,
            // so pressedAt/holding are left untouched (and irrelevant: a
            // matching keyUp in this mode ignores them too).
            return .tap
        case .holdToTalk:
            // Starts immediately, no threshold to clear. holding is set so
            // a mode change mid-press can't strand keyUp — see its .automatic
            // branch, which only ever reads this when mode is .automatic.
            pressedAt = time
            holding = true
            return .holdStart
        case .automatic:
            pressedAt = time
            holding = false
            return nil
        }
    }

    /// Called once the threshold should have elapsed, to promote a press to a hold.
    /// Only `.automatic` ever times a press this way — `.toggle` and
    /// `.holdToTalk` both resolve their gesture on `keyDown` itself, so
    /// `HotkeyMonitor` never even schedules the timer that would call this
    /// in those modes. The `mode` guard here is a second line of defense,
    /// not the only one.
    mutating func elapsedCheck(at time: Double, mode: DictationMode = .automatic) -> HotkeyGesture? {
        guard mode == .automatic else { return nil }
        guard let pressedAt, !holding, time - pressedAt >= holdThreshold else { return nil }
        holding = true
        return .holdStart
    }

    mutating func keyUp(at time: Double, mode: DictationMode = .automatic) -> HotkeyGesture? {
        switch mode {
        case .toggle:
            // Nothing happens on release — the toggle already fired on
            // keyDown.
            return nil
        case .holdToTalk:
            holding = false
            pressedAt = nil
            return .holdEnd
        case .automatic:
            guard let start = pressedAt else { return nil }
            pressedAt = nil

            if holding {
                holding = false
                return .holdEnd
            }
            // The timer may never have fired; classify from the release itself.
            return time - start >= holdThreshold ? .holdEnd : .tap
        }
    }
}

/// Bridges the global shortcut to gestures.
///
/// KeyboardShortcuts registers through Carbon's `RegisterEventHotKey`, which
/// needs no Input Monitoring permission — one fewer prompt for the user.
@MainActor
final class HotkeyMonitor {
    var onGesture: ((HotkeyGesture) -> Void)?

    /// Read fresh on every press and release, so a mode change made in
    /// Settings mid-session takes effect on the very next gesture rather
    /// than needing a relaunch. Defaults to `.automatic` — today's
    /// behavior — for any caller that never wires this up (only
    /// `AppDelegate`, which always does, constructs a real one).
    var dictationMode: () -> DictationMode = { .automatic }

    private var interpreter = HotkeyInterpreter()
    private var holdTimer: Task<Void, Never>?
    private var isActivated = false

    /// Monotonic, unlike wall-clock time, which can jump.
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    func activate() {
        // KeyboardShortcuts appends handlers rather than replacing them, so a
        // second call would register duplicate closures for the same event.
        guard !isActivated else { return }
        isActivated = true

        KeyboardShortcuts.onKeyDown(for: .dictate) { [weak self] in
            guard let self else { return }
            let mode = self.dictationMode()
            if let gesture = self.interpreter.keyDown(at: self.now, mode: mode) {
                self.onGesture?(gesture)
            }

            // Only `.automatic` ever needs to promote a press to a hold
            // after the threshold — `.toggle` and `.holdToTalk` both
            // already resolved their gesture above, on the press itself,
            // so the hold timer must never even run for them.
            guard mode == .automatic else { return }
            self.holdTimer?.cancel()
            self.holdTimer = Task { @MainActor in
                try? await Task.sleep(for: HotkeyInterpreter.holdThreshold)
                guard !Task.isCancelled else { return }
                if let gesture = self.interpreter.elapsedCheck(at: self.now, mode: self.dictationMode()) {
                    self.onGesture?(gesture)
                }
                self.holdTimer = nil
            }
        }

        KeyboardShortcuts.onKeyUp(for: .dictate) { [weak self] in
            guard let self else { return }
            self.holdTimer?.cancel()
            self.holdTimer = nil
            if let gesture = self.interpreter.keyUp(at: self.now, mode: self.dictationMode()) {
                self.onGesture?(gesture)
            }
        }
    }
}
