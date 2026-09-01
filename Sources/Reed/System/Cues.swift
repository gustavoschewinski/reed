import AppKit

enum Cues {
    /// `NSSound.play()` is asynchronous; nothing else in the app holds a
    /// reference to the sound afterward, so ARC is free to deallocate it
    /// before playback finishes. This keeps a strong reference for exactly as
    /// long as playback is in flight, then lets go once the delegate reports
    /// completion (or the sound never started).
    final class PlaybackRetainer: NSObject, NSSoundDelegate, @unchecked Sendable {
        static let shared = PlaybackRetainer()

        private let lock = NSLock()
        private var playing: Set<NSSound> = []

        /// Exposed for tests, which exercise `retain`/`release` and need to
        /// confirm the set actually drains — not reachable from app code.
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return playing.count
        }

        func retain(_ sound: NSSound) {
            lock.lock()
            playing.insert(sound)
            lock.unlock()
        }

        func release(_ sound: NSSound) {
            lock.lock()
            playing.remove(sound)
            lock.unlock()
        }

        // AppKit delivers this from whatever thread the underlying sound
        // engine finishes on (`__NSThreadPerformPerform` in the crash
        // trace) — not necessarily the main thread, despite `Cues`'s
        // otherwise-main-actor world. Leaving this `@MainActor`-isolated
        // let Swift's executor check dereference a bad address off-main
        // and crash the whole process. `release` only takes `lock` and
        // mutates `playing`, both already safe from any thread, so this
        // callback needs no actor at all — just do the work.
        nonisolated func sound(_ sound: NSSound, didFinishPlaying finished: Bool) {
            release(sound)
        }
    }

    private static func play(_ name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "aiff") else {
            NSLog("Reed: cue sound \"\(name)\" not found in the app bundle")
            return
        }
        guard let sound = NSSound(contentsOf: url, byReference: true) else {
            NSLog("Reed: cue sound \"\(name)\" failed to load")
            return
        }
        sound.volume = 0.35
        sound.delegate = PlaybackRetainer.shared
        PlaybackRetainer.shared.retain(sound)
        guard sound.play() else {
            NSLog("Reed: cue sound \"\(name)\" failed to start playing")
            PlaybackRetainer.shared.release(sound)
            return
        }
    }

    static func start() { play("start") }
    static func stop() { play("stop") }
    static func cancel() { play("cancel") }
}
