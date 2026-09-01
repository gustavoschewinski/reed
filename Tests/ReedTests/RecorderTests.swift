import AVFoundation
import Testing
@testable import Reed

@Test func rmsOfSilenceIsZero() {
    #expect(AudioMath.rms([Float](repeating: 0, count: 512)) == 0)
}

@Test func rmsOfFullScaleSquareWaveIsOne() {
    let samples = (0..<512).map { $0.isMultiple(of: 2) ? Float(1) : Float(-1) }
    #expect(abs(AudioMath.rms(samples) - 1.0) < 0.0001)
}

@Test func rmsOfEmptyBufferIsZeroNotNaN() {
    #expect(AudioMath.rms([]) == 0)
}

@Test func rmsOfAlternatingFullAndZeroIsNotPeakOrMeanAbsolute() {
    // For alternating 1.0/0.0, RMS ≈ 0.7071, mean-absolute = 0.5, peak = 1.0.
    // A peak-detector or mean-absolute stand-in would fail this.
    let samples = (0..<512).map { $0.isMultiple(of: 2) ? Float(1) : Float(0) }
    #expect(abs(AudioMath.rms(samples) - 0.70710678) < 0.0001)
}

@Test func conversionResamplesTo16kHzMono() throws {
    let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 48_000)!
    buffer.frameLength = 48_000  // exactly one second

    let output = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: reedSampleRate,
        channels: 1, interleaved: false
    )!
    let samples = try AudioMath.convert(buffer: buffer, to: output)

    // One second at 16 kHz, allowing for resampler edge effects.
    #expect(abs(samples.count - 16_000) < 200)
}

// MARK: - AudioFormatValidation
//
// The predicate `Recorder.start()` uses to refuse handing `installTap` a
// degenerate format (denied microphone permission, or no usable input
// device at all) rather than let it raise an uncatchable Objective-C
// exception. `Recorder` itself opens real hardware and isn't unit-tested by
// design, but this guard is a pure function of a sample rate and a channel
// count, so it's extracted and tested on its own — same reasoning as
// `PendingDeletionController`/`WindowPolicyTracker`.

@Test func aNormal48kHzStereoFormatIsUsable() {
    #expect(AudioFormatValidation.isUsable(sampleRate: 48_000, channelCount: 2))
}

@Test func zeroSampleRateIsRejected() {
    #expect(!AudioFormatValidation.isUsable(sampleRate: 0, channelCount: 2))
}

@Test func zeroChannelCountIsRejected() {
    #expect(!AudioFormatValidation.isUsable(sampleRate: 48_000, channelCount: 0))
}

@Test func zeroSampleRateAndZeroChannelCountAreBothRejected() {
    #expect(!AudioFormatValidation.isUsable(sampleRate: 0, channelCount: 0))
}

/// A 1 kHz sine, resampled 44.1 kHz → 16 kHz the way a live capture
/// arrives: many small buffers, one after another.
private func chunkedResample(chunkFrames: AVAudioFrameCount) throws -> [Float] {
    let input = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
    let output = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let resampler = try #require(StreamingResampler(from: input, to: output))

    var out: [Float] = []
    var frame = 0
    while frame < 44_100 {
        let count = min(chunkFrames, AVAudioFrameCount(44_100 - frame))
        let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: count)!
        buffer.frameLength = count
        for i in 0..<Int(count) {
            buffer.floatChannelData![0][i] = sin(2 * .pi * 1_000 * Float(frame + i) / 44_100)
        }
        out += try resampler.append(buffer)
        frame += Int(count)
    }
    return out + (try resampler.flush())
}

@Test func streamingResamplerKeepsEverySecondOfAudio() throws {
    // One second in, one second out: 16 kHz × 1 s, within a frame or two of
    // filter latency. The per-buffer converter this replaced dropped or
    // duplicated frames at every boundary instead.
    let out = try chunkedResample(chunkFrames: 1024)
    #expect(abs(out.count - 16_000) <= 64)
}

@Test func streamingResamplerHasNoDiscontinuityAtChunkBoundaries() throws {
    // A 1 kHz sine at 16 kHz steps at most sin(2π·1000/16000) ≈ 0.38
    // between samples. A filter restarted at every chunk boundary — what a
    // converter built per buffer does — shows jumps well past that.
    let out = try chunkedResample(chunkFrames: 1024)
    let biggestStep = zip(out, out.dropFirst()).map { abs($1 - $0) }.max() ?? 0
    #expect(biggestStep < 0.5)
}

@Test func resamplingIsIndependentOfHowTheAudioIsChunked() throws {
    // The same second of audio, delivered in different buffer sizes, must
    // resample to the same samples: chunking is a transport detail of the
    // capture callback, not something the model should ever hear.
    let small = try chunkedResample(chunkFrames: 512)
    let large = try chunkedResample(chunkFrames: 4096)
    let common = min(small.count, large.count)
    #expect(abs(small.count - large.count) <= 64)
    let worst = (0..<common).map { abs(small[$0] - large[$0]) }.max() ?? 0
    #expect(worst < 0.02)
}
