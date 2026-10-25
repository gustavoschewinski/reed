import AppKit
import KeyboardShortcuts
import SwiftUI

/// Replaces `KeyboardShortcuts.Recorder`, which reads its placeholder text
/// from the package's SwiftPM resource bundle. That bundle's generated
/// accessor looks in the app root — where a signed .app cannot hold files —
/// and otherwise at the build machine's .build path, so on any other Mac the
/// first Recorder on screen hits a fatalError. Recording itself needs none of
/// the package's UI, only `Shortcut(event:)` and `setShortcut`.
struct ShortcutRecorder: View {
    let name: KeyboardShortcuts.Name
    var onChange: (() -> Void)?

    @State private var shortcut: KeyboardShortcuts.Shortcut?
    @State private var isRecording = false
    @State private var monitor: Any?

    init(for name: KeyboardShortcuts.Name, onChange: (() -> Void)? = nil) {
        self.name = name
        self.onChange = onChange
        _shortcut = State(initialValue: KeyboardShortcuts.getShortcut(for: name))
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleRecording) {
                Text(label)
                    .frame(minWidth: 110)
            }
            .accessibilityLabel("Shortcut")
            .accessibilityValue(label)
            if shortcut != nil, !isRecording {
                Button {
                    commit(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear shortcut")
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private var label: String {
        if isRecording { return "Press shortcut…" }
        return shortcut?.displayName ?? "Record Shortcut"
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        // The live hotkey would otherwise fire while the user is picking it.
        KeyboardShortcuts.disable(name)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard isRecording else { return }
        isRecording = false
        KeyboardShortcuts.enable(name)
    }

    private func handle(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .capsLock, .numericPad])
        switch Int(event.keyCode) {
        case 53 where modifiers.isEmpty:  // Esc
            stopRecording()
        case 51 where modifiers.isEmpty, 117 where modifiers.isEmpty:  // Delete
            commit(nil)
        default:
            // A bare letter would hijack typing everywhere; F-keys are the
            // one safe exception.
            guard let new = KeyboardShortcuts.Shortcut(event: event),
                !modifiers.isEmpty || new.isFunctionKey
            else { return }
            commit(new)
        }
    }

    private func commit(_ new: KeyboardShortcuts.Shortcut?) {
        shortcut = new
        KeyboardShortcuts.setShortcut(new, for: name)
        stopRecording()
        onChange?()
    }
}

extension KeyboardShortcuts.Shortcut {
    /// Stands in for `description`, which renders the Space key through the
    /// package's SwiftPM resource bundle and hits the same fatalError as the
    /// stock Recorder on any Mac but the build machine. Everything else
    /// comes from the package.
    @MainActor
    var displayName: String {
        guard key == .space else { return description }
        let glyphs = [
            (NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"),
            (.shift, "⇧"), (.command, "⌘"),
        ]
        return glyphs.filter { modifiers.contains($0.0) }.map(\.1).joined() + "Space"
    }
}

private extension KeyboardShortcuts.Shortcut {
    var isFunctionKey: Bool {
        let fKeys: Set<KeyboardShortcuts.Key> = [
            .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10,
            .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20,
        ]
        return key.map(fKeys.contains) ?? false
    }
}
