import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let dictate = Self("dictate")
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

    mutating func keyDown(at time: Double) -> HotkeyGesture? {
        pressedAt = time
        holding = false
        return nil
    }

    /// Called once the threshold should have elapsed, to promote a press to a hold.
    mutating func elapsedCheck(at time: Double) -> HotkeyGesture? {
        guard let pressedAt, !holding, time - pressedAt >= holdThreshold else { return nil }
        holding = true
        return .holdStart
    }

    mutating func keyUp(at time: Double) -> HotkeyGesture? {
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

/// Bridges the global shortcut to gestures.
///
/// KeyboardShortcuts registers through Carbon's `RegisterEventHotKey`, which
/// needs no Input Monitoring permission — one fewer prompt for the user.
@MainActor
final class HotkeyMonitor {
    var onGesture: ((HotkeyGesture) -> Void)?

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
            _ = self.interpreter.keyDown(at: self.now)

            // Promote to a hold if the key is still down after the threshold.
            self.holdTimer?.cancel()
            self.holdTimer = Task { @MainActor in
                try? await Task.sleep(for: HotkeyInterpreter.holdThreshold)
                guard !Task.isCancelled else { return }
                if let gesture = self.interpreter.elapsedCheck(at: self.now) {
                    self.onGesture?(gesture)
                }
                self.holdTimer = nil
            }
        }

        KeyboardShortcuts.onKeyUp(for: .dictate) { [weak self] in
            guard let self else { return }
            self.holdTimer?.cancel()
            self.holdTimer = nil
            if let gesture = self.interpreter.keyUp(at: self.now) {
                self.onGesture?(gesture)
            }
        }
    }
}
