import AppKit
import CoreAudio
import KeyboardShortcuts
import SwiftUI

/// The main window's third tab. Exactly six controls, nothing more: one
/// model, one language-agnostic transcriber (Parakeet v3 covers 25
/// languages on its own), so there is no model picker and no language
/// picker to add.
///
/// Labels are written as things the user controls ("Mute other audio while
/// recording"), in sentence case — not as switch names ("Enable output
/// muting").
@MainActor
struct SettingsView: View {
    @ObservedObject var settings: Settings

    @State private var devices: [AudioInputDevice] = []
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                section("Hotkey") {
                    HStack {
                        Text("Dictation shortcut")
                            .foregroundColor(Theme.Window.textPrimary)
                        Spacer()
                        KeyboardShortcuts.Recorder(for: .dictate)
                    }
                }

                section("Audio") {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Microphone")
                                .foregroundColor(Theme.Window.textPrimary)
                            Spacer()
                            Picker("", selection: $settings.inputDeviceID) {
                                Text("System Default").tag(AudioDeviceID?.none)
                                ForEach(devices) { device in
                                    Text(device.name).tag(AudioDeviceID?.some(device.id))
                                }
                                // The saved device may not be plugged in
                                // right now. Without an entry for it, no tag
                                // in this Picker would match the current
                                // selection — and on macOS an unmatched
                                // selection gets silently reassigned to the
                                // first item, *writing that back* through
                                // the two-way binding the instant this view
                                // renders. Rendering Settings must never
                                // change a stored setting, so this keeps a
                                // (disabled — it can't be "chosen" again
                                // without being plugged back in) placeholder
                                // entry for exactly that ID, purely so the
                                // selection still has somewhere to match.
                                if let missingDeviceID {
                                    Text("Unavailable Microphone")
                                        .tag(AudioDeviceID?.some(missingDeviceID))
                                        .disabled(true)
                                }
                            }
                            .labelsHidden()
                            .accessibilityLabel("Microphone")
                            .frame(maxWidth: 220)
                        }

                        toggleRow("Play sounds while recording", isOn: $settings.playSounds)
                        toggleRow("Mute other audio while recording", isOn: $settings.muteWhileRecording)
                        toggleRow("Pause media while recording", isOn: $settings.pauseMediaWhileRecording)
                    }
                }

                section("Startup") {
                    Toggle("Launch Reed at login", isOn: $launchAtLogin)
                        .tint(Theme.Window.reed)
                        .foregroundColor(Theme.Window.textPrimary)
                        .onChange(of: launchAtLogin) { _, newValue in
                            LaunchAtLogin.isEnabled = newValue
                        }
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Window.ink)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            reload()
        }
    }

    private func reload() {
        devices = AudioDevices.inputs()
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    /// The saved input device's ID, but only when it's *not* among the
    /// currently connected `devices` — i.e. only when the picker actually
    /// needs a placeholder entry for it. `nil` whenever the saved device is
    /// connected (it already has a real entry) or when the setting is
    /// System Default (nothing to place).
    private var missingDeviceID: AudioDeviceID? {
        guard let id = settings.inputDeviceID, !devices.contains(where: { $0.id == id }) else {
            return nil
        }
        return id
    }

    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.Window.textDim)
                .textCase(.uppercase)
            content()
        }
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .tint(Theme.Window.reed)
            .foregroundColor(Theme.Window.textPrimary)
    }
}
