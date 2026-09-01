import AVFoundation
import CoreAudio

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

/// Captures the microphone and publishes 16 kHz mono samples as they arrive.
@MainActor
final class Recorder {
    /// Every converted chunk, in order. Drives the transcription loop.
    var onSamples: (([Float]) -> Void)?
    /// Loudness of the latest chunk, 0...1. Drives the waveform.
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private var collected: [Float] = []
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: reedSampleRate,
        channels: 1, interleaved: false
    )!

    func start(deviceID: AudioDeviceID? = nil) throws {
        collected = []

        if let deviceID {
            var id = deviceID
            let unit = engine.inputNode.audioUnit!
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                0, &id, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else { throw RecorderError.deviceUnavailable }
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let samples = try? AudioMath.convert(buffer: buffer, to: self.targetFormat),
                  !samples.isEmpty
            else { return }

            let level = AudioMath.rms(samples)
            Task { @MainActor in
                self.collected.append(contentsOf: samples)
                self.onSamples?(samples)
                self.onLevel?(level)
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
        return collected
    }
}
