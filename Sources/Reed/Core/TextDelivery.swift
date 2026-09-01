import AppKit
import ApplicationServices

protocol ClipboardStore: AnyObject {
    var string: String? { get set }
    /// Every item currently on the pasteboard, in every type it was offered in.
    func snapshot() -> [NSPasteboardItem]
    func restore(_ items: [NSPasteboardItem])
}

final class SystemClipboard: ClipboardStore {
    var string: String? {
        get { NSPasteboard.general.string(forType: .string) }
        set {
            NSPasteboard.general.clearContents()
            if let newValue { NSPasteboard.general.setString(newValue, forType: .string) }
        }
    }

    func snapshot() -> [NSPasteboardItem] {
        // `clearContents()` invalidates the items vended by the system
        // pasteboard, so each one must be copied — a fresh item with every
        // type's data re-set — before we write over it.
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    func restore(_ items: [NSPasteboardItem]) {
        NSPasteboard.general.clearContents()
        if !items.isEmpty {
            NSPasteboard.general.writeObjects(items)
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
        clipboard: any ClipboardStore = SystemClipboard(),
        canPaste: Bool? = nil,
        paste: (() -> Void)? = nil,
        restoreAfter: Duration = .milliseconds(150)
    ) async {
        let canPaste = canPaste ?? accessibilityGranted
        let paste = paste ?? pressCommandV

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard canPaste else {
            clipboard.string = trimmed
            return
        }

        let previous = clipboard.snapshot()
        clipboard.string = trimmed
        paste()

        // The paste is asynchronous in the receiving app; restoring immediately
        // would race it.
        try? await Task.sleep(for: restoreAfter)
        clipboard.restore(previous)
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
        // The literal has been the stable public value of
        // `kAXTrustedCheckOptionPrompt` for over a decade; using it directly
        // avoids referencing that global `var`, which Swift 6 strict
        // concurrency flags as shared mutable state.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}
