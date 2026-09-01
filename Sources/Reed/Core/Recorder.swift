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

        var consumed = false
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
            return buffer
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

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
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

        engine.prepare()
        try engine.start()
    }

    /// Stops capture and returns the complete recording.
    @discardableResult
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return buffer.drain()
    }
}
