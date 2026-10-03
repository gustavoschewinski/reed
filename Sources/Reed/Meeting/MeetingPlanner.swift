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
