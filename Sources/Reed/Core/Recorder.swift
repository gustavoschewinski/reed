import AVFoundation
import CoreAudio
import Foundation

/// Sample rate Parakeet expects. Everything upstream converts to this.
let reedSampleRate = 16_000.0

enum AudioMath {
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(samples.count)).squareRoot()
    }

    static func convert(buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> [Float] {
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            throw RecorderError.conversionUnavailable
        }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw RecorderError.conversionUnavailable
        }

        // `AVAudioConverterInputBlock` is `@Sendable` by API contract, but
        // `AVAudioConverter.convert(to:error:withInputFrom:)` only ever
        // calls it synchronously and repeatedly on the calling thread, for
        // the duration of this one `convert` call — never concurrently,
        // and never after this function returns. The compiler can't see
        // that from the type system alone (`AVAudioPCMBuffer` itself isn't
        // `Sendable`, and this SDK's AVFAudio isn't `@preconcurrency`-
        // annotated), so `nonisolated(unsafe)` records that guarantee
        // explicitly rather than leaving a strict-concurrency warning that
        // would otherwise be the only ones a clean rebuild produces
        // besides Item 7's own `AudioDevices.swift` leak.
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let inputBuffer = buffer
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                // .endOfStream (not .noDataNow) tells the converter this buffer is
                // definitively the last input, so it flushes the resampler's internal
                // filter tail instead of withholding it for data that will never arrive.
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return inputBuffer
        }
        if let error { throw error }

        guard let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

/// Resamples a live capture stream to Reed's 16 kHz mono format, keeping
/// one converter for the whole recording.
///
/// A converter built per buffer — what this replaced — has to be flushed
/// (`.endOfStream`) on every call or it loses its filter tail, which
/// restarts the resampling filter roughly twelve times a second, at every
/// chunk boundary, across all of the audio the model ever sees. One
/// converter lets the filter run continuously instead: `.noDataNow` parks
/// its tail until the next buffer arrives, and `flush()` collects it once,
/// at the end.
///
/// `@unchecked Sendable` because access is exclusive by ordering, not by a
/// lock: `append` is only ever called from the audio tap, and `flush` only
/// after `engine.stop()` has returned — which guarantees the render thread
/// is not mid-callback.
final class StreamingResampler: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let ratio: Double

    init?(from input: AVAudioFormat, to output: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: input, to: output) else { return nil }
        self.converter = converter
        self.outputFormat = output
        self.ratio = output.sampleRate / input.sampleRate
    }

    /// Converts one captured buffer. The resampler's tail stays inside the
    /// converter for the next call rather than being flushed here.
    func append(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let input = buffer
        return try run(capacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
    }

    /// Drains whatever the filter is still holding. Call once, after the
    /// last `append`, or the final fraction of a second is lost.
    func flush() throws -> [Float] {
        try run(capacity: 4096) { _, status in
            status.pointee = .endOfStream
            return nil
        }
    }

    private func run(
        capacity: AVAudioFrameCount,
        block: @escaping AVAudioConverterInputBlock
    ) throws -> [Float] {
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw RecorderError.conversionUnavailable
        }
        var error: NSError?
        converter.convert(to: output, error: &error, withInputFrom: block)
        if let error { throw error }
        guard let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

enum RecorderError: Error {
    case conversionUnavailable
    case deviceUnavailable
}

/// The two things that must hold before `AVAudioEngine.installTap` is
/// handed a format. `installTap` validates neither itself: it raises an
/// Objective-C exception ("required condition is false…") rather than
/// returning an error, and those are what these predicates exist to
/// prevent.
///
/// Extracted as pure, `Recorder`-independent predicates — unlike the rest
/// of `Recorder`, which opens real hardware and is verified by hand, not
/// unit-tested by design — so these guards can be tested without a
/// microphone, the way `PendingDeletionController` and `WindowPolicyTracker`
/// were pulled out of their owning types for the same reason.
enum AudioFormatValidation {
    /// Whether the format the input node reports is non-degenerate. A denied
    /// microphone permission — or simply no usable input device at the moment
    /// capture is requested — makes the input node report zero sample rate and
    /// zero channels.
    static func isUsable(sampleRate: Double, channelCount: AVAudioChannelCount) -> Bool {
        sampleRate > 0 && channelCount > 0
    }

    /// Whether a tap format may be installed against a given input hardware
    /// format. Mirrors the condition AVFAudio asserts internally:
    ///
    ///     required condition is false:
    ///     [AVAudioEngineGraph.mm:InstallTapOnNode:
    ///      (format.sampleRate == inputHWFormat.sampleRate)]
    ///
    /// This is not hypothetical. `Recorder.start()` used to read its tap
    /// format from `inputNode.outputFormat(forBus: 0)`, which intermittently
    /// reports the *output* device's sample rate rather than the
    /// microphone's — on a Mac whose speakers run at 44.1 kHz and whose
    /// microphone runs at 48 kHz, that mismatch raised the exception above
    /// and, because AppKit catches it at the top of the run loop, left the
    /// app running but permanently unable to record until relaunched.
    /// `start()` now reads the hardware format directly, so the two agree by
    /// construction; this guard is what makes that a checked invariant
    /// rather than an assumption.
    static func canInstallTap(tapSampleRate: Double, hardwareSampleRate: Double) -> Bool {
        tapSampleRate > 0 && tapSampleRate == hardwareSampleRate
    }
}

/// Thread-safe accumulator for converted samples. The audio-render thread appends
/// synchronously (no async hop, no race with `drain()`), while `Recorder` reads/resets
/// it from the main actor. Marked `@unchecked Sendable` because the `NSLock` makes every
/// access to `samples` mutually exclusive regardless of which thread calls in.
private final class SampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func append(_ new: [Float]) {
        lock.lock()
        samples.append(contentsOf: new)
        lock.unlock()
    }

    /// Returns everything accumulated so far. Does not clear — call `reset()` separately.
    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    func reset() {
        lock.lock()
        samples = []
        lock.unlock()
    }
}

/// Captures the microphone and publishes 16 kHz mono samples as they arrive.
@MainActor
final class Recorder {
    /// Every converted chunk, in order. Drives the transcription loop.
    var onSamples: (([Float]) -> Void)?
    /// Loudness of the latest chunk, 0...1. Drives the waveform.
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private let buffer = SampleBuffer()
    /// Lives for one recording: created in `start()` against the input
    /// format the microphone actually negotiated, drained in `stop()`.
    private var resampler: StreamingResampler?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: reedSampleRate,
        channels: 1, interleaved: false
    )!

    func start(deviceID: AudioDeviceID? = nil) throws {
        DebugLog.log("Recorder.start() entry, deviceID=\(deviceID.map(String.init(describing:)) ?? "default")")
        buffer.reset()

        if let deviceID {
            var id = deviceID
            guard let unit = engine.inputNode.audioUnit else {
                throw RecorderError.deviceUnavailable
            }
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                0, &id, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else { throw RecorderError.deviceUnavailable }
        }

        // `prepare()` allocates the engine's render resources and settles
        // its node connections; called before reading the input node's
        // format (rather than after, as this used to), it gives a real,
        // present microphone a chance to report its actual negotiated
        // format instead of whatever placeholder the node holds before the
        // graph has ever been prepared. It does not change the outcome
        // when there is genuinely no usable input — permission denied, or
        // no device at all — the format is degenerate either way, which is
        // exactly what the validation below exists to catch regardless of
        // *why* it's degenerate.
        // The input node must exist before `prepare()`: `AVAudioEngine`
        // creates it lazily on first access, and preparing an engine with
        // no nodes at all raises an NSException ("inputNode != nullptr ||
        // outputNode != nullptr") that Swift cannot catch.
        let input = engine.inputNode
        engine.prepare()

        // `inputFormat(forBus: 0)`, not `outputFormat(forBus: 0)`. They are
        // usually the same value, but not always, and `installTap` accepts
        // only one of them: it asserts `format.sampleRate ==
        // inputHWFormat.sampleRate`, and `inputFormat` *is* that hardware
        // format, while `outputFormat` is what the node reports downstream
        // into the graph. On a Mac whose speakers run at 44.1 kHz and whose
        // microphone runs at 48 kHz, `outputFormat` intermittently returned
        // the speakers' rate — most often right after the start cue opened
        // the output device a few milliseconds earlier — and the resulting
        // exception left Reed running but unable to record until relaunched.
        // Reading the hardware format is what makes the tap install agree
        // with it by construction.
        let inputFormat = input.inputFormat(forBus: 0)
        DebugLog.log(
            "Recorder.start() input format sampleRate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount)"
        )
        guard AudioFormatValidation.isUsable(
            sampleRate: inputFormat.sampleRate, channelCount: inputFormat.channelCount
        ) else {
            throw RecorderError.deviceUnavailable
        }

        guard let resampler = StreamingResampler(from: inputFormat, to: targetFormat) else {
            throw RecorderError.conversionUnavailable
        }
        self.resampler = resampler
        let buffer = self.buffer

        // Re-read immediately before the install, not reused from above: the
        // default input device can change between the two — a headset
        // connecting, a call ending — and `installTap` compares the format it
        // is handed against whatever the hardware format is *at that moment*.
        // Refusing here costs the user one failed dictation with an
        // explanation; letting the rates disagree costs them every dictation
        // until they relaunch Reed.
        let hardwareFormat = input.inputFormat(forBus: 0)
        guard AudioFormatValidation.canInstallTap(
            tapSampleRate: inputFormat.sampleRate, hardwareSampleRate: hardwareFormat.sampleRate
        ) else {
            DebugLog.log(
                "Recorder.start() refused the tap: rate \(inputFormat.sampleRate) "
                    + "disagrees with the hardware's \(hardwareFormat.sampleRate)")
            self.resampler = nil
            throw RecorderError.deviceUnavailable
        }

        // `@Sendable` keeps the closure out of MainActor isolation: a plain
        // closure formed here inherits it, and the Swift 6 runtime then
        // SIGTRAPs (`dispatch_assert_queue_fail`) when AVFAudio invokes the
        // tap on its own realtime queue.
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { @Sendable [weak self] pcmBuffer, _ in
            let samples: [Float]
            do {
                samples = try resampler.append(pcmBuffer)
            } catch {
                // No onError callback exists (deliberately, per interface scope); log so a
                // dropped chunk during recording is at least visible instead of silent.
                NSLog("Reed: audio conversion failed: %@", String(describing: error))
                return
            }
            guard !samples.isEmpty else { return }

            // Append synchronously, on the audio-render thread, before this tap callback
            // returns. Once `stop()`'s `engine.stop()` call returns, the render thread
            // cannot be mid-callback, so no further appends are possible and `drain()`
            // is guaranteed to see every sample.
            buffer.append(samples)

            let level = AudioMath.rms(samples)
            // DispatchQueue.main.async is FIFO by contract, unlike separately-created
            // Task { @MainActor in ... } instances, so callback delivery preserves the
            // "in order" guarantee onSamples documents. MainActor.assumeIsolated is safe
            // here because this closure only ever runs once actually scheduled on the
            // main thread, which is what backs the MainActor by default.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.onSamples?(samples)
                    self?.onLevel?(level)
                }
            }
        }

        try engine.start()
        DebugLog.log("Recorder.start() engine started")
    }

    /// Stops capture and returns the complete recording.
    @discardableResult
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        // `engine.stop()` has returned, so the render thread cannot be
        // mid-callback and the resampler is ours to drain: its filter is
        // still holding the last fraction of a second of audio, which no
        // `append` will ever emit.
        if let resampler {
            self.resampler = nil
            if let tail = try? resampler.flush(), !tail.isEmpty {
                buffer.append(tail)
            }
        }
        return buffer.drain()
    }
}
