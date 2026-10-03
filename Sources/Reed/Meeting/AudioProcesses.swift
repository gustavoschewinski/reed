import AppKit
import ApplicationServices
import CoreAudio

enum AudioProcesses {
    /// Every process Core Audio knows about, with whether it is playing or
    /// recording right now. Empty before macOS 14.2 (no process objects).
    static func current() -> [AudioProcess] {
        guard #available(macOS 14.2, *) else { return [] }
        let ids: [AudioObjectID] = CoreAudioProperty.array(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList
        )
        return ids.compactMap { id in
            guard
                let pid: pid_t = CoreAudioProperty.value(id, kAudioProcessPropertyPID),
                let bundle = CoreAudioProperty.string(id, kAudioProcessPropertyBundleID)
            else { return nil }
            let out: UInt32 = CoreAudioProperty.value(id, kAudioProcessPropertyIsRunningOutput) ?? 0
            let input: UInt32 = CoreAudioProperty.value(id, kAudioProcessPropertyIsRunningInput) ?? 0
            return AudioProcess(pid: pid, bundleID: bundle, isRunningOutput: out != 0, isRunningInput: input != 0)
        }
    }

    /// Reed's own process object, so the tap can exclude Reed's cues.
    static func ownProcessObject() -> AudioObjectID? {
        guard #available(macOS 14.2, *) else { return nil }
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = CoreAudioProperty.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
        )
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}

enum CoreAudioProperty {
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    /// Plain-old-data properties only (integers, structs). For CFString
    /// properties use `string(_:_:)`, which owns the +1 reference correctly.
    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.load(as: T.self)
    }

    /// A CFString property. Core Audio hands back a +1 retained reference;
    /// `takeRetainedValue()` consumes exactly that one, so there is no leak
    /// and no over-release (a raw `load(as: CFString.self)` would leave the
    /// +1 unbalanced).
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var result: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let result else { return nil }
        return result.takeRetainedValue() as String
    }

    static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [T] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }
}

enum AppInfo {
    static func name(bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
    }

    /// The focused window's title, via the Accessibility permission Reed
    /// already holds for pasting. `nil` without it — sessions are then
    /// named by app only, which still works.
    static func focusedWindowTitle(bundleID: String) -> String? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        var title: CFTypeRef?
        // swiftlint:disable:next force_cast
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        guard let text = title as? String, !text.isEmpty else { return nil }
        return text
    }
}
