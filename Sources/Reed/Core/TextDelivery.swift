import AppKit
// `kAXTrustedCheckOptionPrompt` is imported as a global `var`, which Swift 6
// strict concurrency would otherwise flag as shared mutable state; it is a
// read-only system constant, so importing it `@preconcurrency` is safe.
@preconcurrency import ApplicationServices

protocol Pasteboard: AnyObject {
    var string: String? { get set }
}

final class SystemPasteboard: Pasteboard {
    var string: String? {
        get { NSPasteboard.general.string(forType: .string) }
        set {
            NSPasteboard.general.clearContents()
            if let newValue { NSPasteboard.general.setString(newValue, forType: .string) }
        }
    }
}

@MainActor
enum TextDelivery {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Puts `text` into the focused app. Without Accessibility permission the
    /// text is left on the clipboard rather than lost.
    static func deliver(
        _ text: String,
        pasteboard: any Pasteboard = SystemPasteboard(),
        canPaste: Bool? = nil,
        paste: (() -> Void)? = nil,
        restoreAfter: Duration = .milliseconds(150)
    ) async {
        let canPaste = canPaste ?? accessibilityGranted
        let paste = paste ?? pressCommandV

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard canPaste else {
            pasteboard.string = trimmed
            return
        }

        let previous = pasteboard.string
        pasteboard.string = trimmed
        paste()

        // The paste is asynchronous in the receiving app; restoring immediately
        // would race it.
        try? await Task.sleep(for: restoreAfter)
        pasteboard.string = previous
    }

    static func pressCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9

        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        up?.flags = .maskCommand

        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
