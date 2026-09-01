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
