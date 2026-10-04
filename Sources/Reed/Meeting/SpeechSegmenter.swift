import Foundation

/// Regroups arbitrarily sized capture buffers into the fixed frames the
/// VAD model takes (`VadManager.chunkSize`).
struct FrameChunker {
    let frameSize: Int
    private var carry: [Float] = []

    init(frameSize: Int = 4096) {
        precondition(frameSize > 0)
        self.frameSize = frameSize
    }

    mutating func push(_ samples: [Float]) -> [[Float]] {
        carry += samples
        var frames: [[Float]] = []
        var start = 0
        while carry.count - start >= frameSize {
            frames.append(Array(carry[start..<start + frameSize]))
            start += frameSize
        }
        carry.removeFirst(start)
        return frames
    }

    /// The leftover samples zero-padded to a full frame, or nil if none.
    /// Call once at the end of the stream so the trailing audio is not lost.
    mutating func flushRemainder() -> [Float]? {
        guard !carry.isEmpty else { return nil }
        let frame = carry + [Float](repeating: 0, count: frameSize - carry.count)
        carry = []
        return frame
    }
}

struct SpeechSegment: Equatable, Sendable {
    /// Sample index within the channel's stream where the segment begins.
    var startSample: Int
    var samples: [Float]
}

/// Turns VAD-labelled frames into stretches of speech worth transcribing.
/// One frame of pre-roll and one of tail keep the first and last syllable;
/// segments are capped so a monologue is still written every ~30 s.
struct SpeechSegmenter {
    private let maxSamples: Int
    private let minSamples: Int
    private var current: [Float] = []
    private var currentStart = 0
    private var previous: [Float] = []
    private var processed = 0
    /// Set after a cut at `maxSamples`: the next segment continues the same
    /// speech, so the previous frame was already emitted and must not be
    /// repeated as pre-roll.
    private var skipPreRoll = false

    /// - Parameters:
    ///   - frameSize: Accepted for symmetry; segments are built from whatever frames are pushed.
    ///   - sampleRate: Sample rate in Hz.
    ///   - maxSeconds: Maximum segment duration in seconds.
    ///   - minSeconds: Minimum segment duration in seconds to emit.
    init(frameSize: Int = 4096, sampleRate: Double = reedSampleRate, maxSeconds: Double = 30, minSeconds: Double = 0.5) {
        maxSamples = Int(maxSeconds * sampleRate)
        minSamples = Int(minSeconds * sampleRate)
    }

    mutating func push(frame: [Float], isSpeech: Bool) -> [SpeechSegment] {
        defer {
            previous = frame
            processed += frame.count
        }
        if isSpeech {
            if current.isEmpty {
                let preRoll = skipPreRoll ? [] : previous
                currentStart = processed - preRoll.count
                current = preRoll
                skipPreRoll = false
            }
            // Check if appending this frame would exceed maxSamples.
            if !current.isEmpty && current.count + frame.count > maxSamples {
                skipPreRoll = true
                let segment = emit()
                // Start the next segment with this frame (no pre-roll because we just emitted).
                currentStart = processed
                current = frame
                return segment
            }
            current += frame
            guard current.count >= maxSamples else { return [] }
            skipPreRoll = true
            return emit()
        }
        guard !current.isEmpty else {
            skipPreRoll = false
            return []
        }
        current += frame
        skipPreRoll = true
        return emit()
    }

    mutating func flush() -> [SpeechSegment] {
        current.isEmpty ? [] : emit()
    }

    private mutating func emit() -> [SpeechSegment] {
        let segment = SpeechSegment(startSample: currentStart, samples: current)
        current = []
        return segment.samples.count >= minSamples ? [segment] : []
    }
}
