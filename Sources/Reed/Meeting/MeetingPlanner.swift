import Foundation

enum SilenceNotice: Equatable {
    /// Tell the user Reed may lack the System Audio Recording permission.
    case show
    /// Real audio arrived: take the notice down.
    case clear
}

/// macOS gives a process tap without the System Audio Recording permission
/// pure zeros rather than an error. "Exactly zero for a minute while some
/// app says it is playing" is how Reed notices.
///
/// Only a hint, never a block: browsers report output while silent and a
/// call's far side can be quiet for minutes, so the tap keeps running and
/// the notice clears itself on the first real sample. Once a tap has
/// delivered any non-zero sample, permission is proven and it never trips
/// again until the next `tapStarted()`.
struct SilenceWatchdog {
    let threshold: TimeInterval
    /// Whether the notice is currently up. Survives `tapStarted()`.
    private(set) var showing = false
    private var proven = false
    private var silentSince: Date?

    init(threshold: TimeInterval = 60) {
        self.threshold = threshold
    }

    /// A new tap is running: its permission is unproven until it hears something.
    mutating func tapStarted() {
        proven = false
        silentSince = nil
    }

    /// The user dismissed or retried: start a fresh silent minute.
    mutating func dismiss() {
        showing = false
        silentSince = nil
    }

    mutating func observe(samplesAreSilent: Bool, someoneIsPlaying: Bool, now: Date) -> SilenceNotice? {
        if !samplesAreSilent {
            proven = true
            silentSince = nil
            guard showing else { return nil }
            showing = false
            return .clear
        }
        guard !proven, someoneIsPlaying else {
            silentSince = nil
            return nil
        }
        let since = silentSince ?? now
        silentSince = since
        guard !showing, now.timeIntervalSince(since) > threshold else { return nil }
        showing = true
        return .show
    }
}

struct CaptureInputs: Equatable {
    var manualOn: Bool
    var autoEnabled: Bool
    /// macOS 14.2+.
    var systemAudioAvailable: Bool
    /// Some other process reported output in the last 10 s (debounced by the controller).
    var somethingPlaying: Bool
    var micInUseElsewhere: Bool
    var dictating: Bool
}

struct CapturePlan: Equatable {
    var systemTap: Bool
    var mic: Bool
}

/// What to capture, from what the user asked for and what the Mac is doing.
/// Auto mode never opens the mic on its own — only while another app
/// already holds it (a call) — so there is no all-day mic indicator and
/// Bluetooth headsets aren't forced into call quality.
enum MeetingPlanner {
    static func plan(_ i: CaptureInputs) -> CapturePlan {
        let tap = i.systemAudioAvailable && (i.manualOn || (i.autoEnabled && i.somethingPlaying))
        let mic = !i.dictating && (i.manualOn || (i.autoEnabled && i.micInUseElsewhere))
        return CapturePlan(systemTap: tap, mic: mic)
    }
}
