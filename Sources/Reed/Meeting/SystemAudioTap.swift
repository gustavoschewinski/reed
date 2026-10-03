import AVFoundation
import CoreAudio

enum SystemAudioTapError: Error {
    case unsupported, tap(OSStatus), noOutputDevice, aggregate(OSStatus), format, ioProc(OSStatus), start(OSStatus)
}

/// Everything the Mac plays (except Reed's own cues), mixed to mono and
/// resampled to 16 kHz. A Core Audio process tap feeding a private
/// aggregate device; macOS 14.2+. Needs "System Audio Recording" — without
/// it macOS delivers silence, see `SilenceWatchdog`.
///
/// `@unchecked Sendable`: `start`/`stop` are called from one owner at a
/// time; the IOProc block runs on `queue` and touches only values captured
/// at start (`handler`, `resampler`, `format`), never this object's state.
final class SystemAudioTap: @unchecked Sendable {
    /// Must be set before `start()`; later changes take effect on the next `start()`.
    var onSamples: (@Sendable ([Float]) -> Void)?

    /// The tap's buffer within the IOProc's input list. The aggregate device
    /// also carries the output sub-device, and if that device has input
    /// streams (a headset mic) their buffers come first; the tap's streams
    /// are appended last. The tap is mono, so it is exactly one buffer.
    static func tapBuffer(in list: UnsafeMutableAudioBufferListPointer) -> AudioBuffer? {
        guard let last = list.last, last.mDataByteSize > 0, last.mData != nil else { return nil }
        return last
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "reed.meeting.system-audio", qos: .userInitiated)

    func start() throws {
        guard #available(macOS 14.2, *) else { throw SystemAudioTapError.unsupported }
        stop()

        let ownProcess = AudioProcesses.ownProcessObject()
        if ownProcess == nil {
            NSLog("Reed: own audio process object not found; Reed's cues are not excluded from the tap")
        }
        if onSamples == nil { NSLog("Reed: SystemAudioTap.start() called with no onSamples handler") }
        let excluded = ownProcess.map { [$0] } ?? []
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.name = "Reed meeting capture"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw SystemAudioTapError.tap(status) }
        tapID = tap

        guard let outputDevice: AudioObjectID = CoreAudioProperty.value(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice),
              let outputUID = CoreAudioProperty.string(outputDevice, kAudioDevicePropertyDeviceUID)
        else { stop(); throw SystemAudioTapError.noOutputDevice }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Reed meeting capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var aggregateDevice = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateDevice)
        guard status == noErr else { stop(); throw SystemAudioTapError.aggregate(status) }
        aggregateID = aggregateDevice

        guard var asbd: AudioStreamBasicDescription = CoreAudioProperty.value(tap, kAudioTapPropertyFormat),
              let format = AVAudioFormat(streamDescription: &asbd),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: reedSampleRate, channels: 1, interleaved: false),
              let resampler = StreamingResampler(from: format, to: target)
        else { stop(); throw SystemAudioTapError.format }

        let handler = onSamples
        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateDevice, queue) { _, input, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let chosen = SystemAudioTap.tapBuffer(in: list) else { return }
            var single = AudioBufferList(mNumberBuffers: 1, mBuffers: chosen)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: &single, deallocator: nil)
            else { return }
            let samples: [Float]
            do { samples = try resampler.append(buffer) } catch {
                NSLog("Reed: system audio conversion failed: %@", String(describing: error))
                return
            }
            guard !samples.isEmpty else { return }
            handler?(samples)
        }
        guard status == noErr, let proc else { stop(); throw SystemAudioTapError.ioProc(status) }
        procID = proc

        status = AudioDeviceStart(aggregateDevice, proc)
        guard status == noErr else { stop(); throw SystemAudioTapError.start(status) }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if #available(macOS 14.2, *), tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }
}
