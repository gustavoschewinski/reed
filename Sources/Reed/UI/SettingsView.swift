import AVFoundation
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
///
/// `accessibilityNotice` below is not a seventh control — it's a
/// conditional problem indicator, shown only while Accessibility isn't
/// granted, and it's the one route back for someone who dismissed
/// onboarding's one-time consent alert without granting it (see
/// `OnboardingModel.openAccessibilitySettings()`'s doc comment for why that
/// alert can't just be re-shown). Preferences are things the user sets;
/// this is Reed telling the user something is wrong, so it stays visually
/// quieter than the six controls — no section header, no reed-tinted
/// prominent button.
@MainActor
struct SettingsView: View {
    @ObservedObject var settings: Settings

    @State private var devices: [AudioInputDevice] = []
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var accessibilityGranted = TextDelivery.accessibilityGranted
    @State private var microphoneDenied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // Onboarding promises "Settings will show you what's still
                // missing" — this and `accessibilityNotice` below are what
                // makes that literally true, matching Item 2's overlay
                // notice with a persistent one here for whenever the
                // overlay isn't on screen to see.
                if microphoneDenied {
                    microphoneNotice
                }
                if !accessibilityGranted {
                    accessibilityNotice
                }

                section("Shortcut") {
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
        accessibilityGranted = TextDelivery.accessibilityGranted
        microphoneDenied = AVCaptureDevice.authorizationStatus(for: .audio) == .denied
            || AVCaptureDevice.authorizationStatus(for: .audio) == .restricted
    }

    /// Mirrors `accessibilityNotice` below — same muted styling, same
    /// "problem indicator, not a seventh control" treatment. Only shown
    /// once macOS has recorded an explicit denial: `.notDetermined` isn't
    /// a problem yet, since starting a recording is what triggers that
    /// system prompt in the first place.
    private var microphoneNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 13))
                .foregroundColor(Theme.Window.textDim)

            VStack(alignment: .leading, spacing: 4) {
                Text("Reed can't hear you")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.Window.textPrimary)
                Text("Microphone access is off, so dictation has nothing to transcribe.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Window.textDim)

                Button("Open System Settings") {
                    SystemSettings.open(.microphone)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.Window.inkRaised.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Shown only while Accessibility isn't granted — see the type's own
    /// doc comment. Deliberately muted: a small icon, `textDim` body copy,
    /// and a plain `.bordered` button rather than the reed-tinted
    /// `.borderedProminent` style the six real controls' actions use.
    private var accessibilityNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 13))
                .foregroundColor(Theme.Window.textDim)

            VStack(alignment: .leading, spacing: 4) {
                Text("Reed can copy but can't paste")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.Window.textPrimary)
                Text(
                    "Without Accessibility, dictated text is left on the clipboard "
                        + "instead of typed into the app you're using."
                )
                .font(.system(size: 11))
                .foregroundColor(Theme.Window.textDim)

                Button("Open System Settings") {
                    SystemSettings.open(.accessibility)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.Window.inkRaised.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
