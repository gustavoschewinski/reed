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

enum RecorderError: Error {
    case conversionUnavailable
    case deviceUnavailable
}

/// Whether a format `AVAudioInputNode.outputFormat(forBus:)` reports is
/// something `AVAudioEngine.installTap` can actually be handed. A denied
/// microphone permission — or simply no usable input device at the moment
/// capture is requested — makes the input node report a degenerate format:
/// zero sample rate, zero channels. `installTap` does not validate that
/// itself; it raises an Objective-C exception ("required condition is
/// false…") that surfaces in Swift as an uncatchable `SIGTRAP`, not a
/// catchable `Error` — the crash this predicate exists to prevent.
///
/// Extracted as a pure, `Recorder`-independent predicate — unlike the rest
/// of `Recorder`, which opens real hardware and is verified by hand, not
/// unit-tested by design — so this one guard can be tested without a
/// microphone, the way `PendingDeletionController` and `WindowPolicyTracker`
/// were pulled out of their owning types for the same reason.
enum AudioFormatValidation {
    static func isUsable(sampleRate: Double, channelCount: AVAudioChannelCount) -> Bool {
        sampleRate > 0 && channelCount > 0
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
        engine.prepare()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        DebugLog.log(
            "Recorder.start() input format sampleRate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount)"
        )
        guard AudioFormatValidation.isUsable(
            sampleRate: inputFormat.sampleRate, channelCount: inputFormat.channelCount
        ) else {
            throw RecorderError.deviceUnavailable
        }

        let targetFormat = self.targetFormat
        let buffer = self.buffer

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] pcmBuffer, _ in
            let samples: [Float]
            do {
                samples = try AudioMath.convert(buffer: pcmBuffer, to: targetFormat)
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
        return buffer.drain()
    }
}
