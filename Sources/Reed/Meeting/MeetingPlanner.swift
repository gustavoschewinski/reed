import Foundation

/// macOS gives a process tap without the System Audio Recording permission
/// pure zeros rather than an error. "Exactly zero for a minute while some
/// app says it is playing" is how Reed notices — real audio, even quiet,
/// is never bit-exact zero for that long.
struct SilenceWatchdog {
    let threshold: TimeInterval
    private var silentSince: Date?

    init(threshold: TimeInterval = 60) {
        self.threshold = threshold
    }

    mutating func observe(samplesAreSilent: Bool, someoneIsPlaying: Bool, now: Date) -> Bool {
        guard samplesAreSilent, someoneIsPlaying else {
            silentSince = nil
            return false
        }
        let since = silentSince ?? now
        silentSince = since
        return now.timeIntervalSince(since) > threshold
    }
}

struct CaptureInputs: Equatable {
    var manualOn: Bool
    var autoEnabled: Bool
    /// macOS 14.2+ and the tap isn't known to be permission-blocked.
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
