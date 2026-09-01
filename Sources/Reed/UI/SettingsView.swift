import AVFoundation
import AppKit
import CoreAudio
import KeyboardShortcuts
import SwiftUI

/// The main window's third tab. Originally exactly six controls and
/// nothing more — one model, one language-agnostic transcriber (Parakeet
/// v3 covers 25 languages on its own), so there was no model picker and no
/// language picker to add. The dictation-mode picker below is a deliberate
/// exception to that rule, not an erosion of it: it was asked for
/// specifically, and it changes what the shortcut *does* rather than
/// reporting a status, so it belongs directly under the shortcut recorder
/// it modifies.
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
    @State private var microphoneStatus: AVAuthorizationStatus = .authorized
    @State private var requestingMicrophoneAccess = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // Onboarding promises "Settings will show you what's still
                // missing" — this and `accessibilityNotice` below are what
                // makes that literally true, matching Item 2's overlay
                // notice with a persistent one here for whenever the
                // overlay isn't on screen to see. Covers `.notDetermined`
                // too, not just `.denied`: someone whose onboarding was
                // skipped or interrupted has never been asked at all, and
                // without a route back in here, that's exactly the kind of
                // stranding this project has fought before — the shortcut
                // says permission is needed, and nothing here explains why.
                if let microphoneNoticeKind {
                    microphoneNotice(microphoneNoticeKind)
                }
                if !accessibilityGranted {
                    accessibilityNotice
                }

                section("Shortcut") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Dictation shortcut")
                                .foregroundColor(Theme.Window.textPrimary)
                            Spacer()
                            KeyboardShortcuts.Recorder(for: .dictate)
                        }

                        // Directly under the recorder, not in its own
                        // section: it modifies what the shortcut above does,
                        // rather than being an independent preference.
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("When you press it")
                                    .foregroundColor(Theme.Window.textPrimary)
                                Spacer()
                                Picker("", selection: $settings.dictationMode) {
                                    Text("Press to start and stop").tag(DictationMode.toggle)
                                    Text("Hold to talk").tag(DictationMode.holdToTalk)
                                    Text("Automatic").tag(DictationMode.automatic)
                                }
                                .labelsHidden()
                                .accessibilityLabel("When you press it")
                                .frame(maxWidth: 220)
                            }
                            if settings.dictationMode == .automatic {
                                Text("Automatic: a quick press toggles; holding it down talks instead.")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.Window.textDim)
                            }
                        }
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
                        toggleRow(
                            "Pause media while recording",
                            isOn: $settings.pauseMediaWhileRecording,
                            note: "macOS doesn't tell apps whether media is playing, so this "
                                + "can start something that was paused. Muting already silences "
                                + "playback while you dictate."
                        )
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
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// What (if anything) `microphoneNotice` should show. `nil` means
    /// authorized — nothing to say. Kept as its own type, rather than two
    /// separate bools, so the two states stay mutually exclusive by
    /// construction.
    private enum MicrophoneNoticeKind {
        /// Never asked — onboarding was skipped or interrupted, or this is
        /// a fresh install. Distinct from `.denied`: nothing has been
        /// turned off, so the notice must not say "turn it back on."
        case notDetermined
        /// Asked, and said no (or the OS restricted it).
        case denied
    }

    private var microphoneNoticeKind: MicrophoneNoticeKind? {
        switch microphoneStatus {
        case .authorized: return nil
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    /// Mirrors `accessibilityNotice` below — same muted styling, same
    /// "problem indicator, not a seventh control" treatment. Wording
    /// (and the action offered) differs by `kind`: someone who has never
    /// been asked needs a different sentence, and a different fix, than
    /// someone who said no.
    private func microphoneNotice(_ kind: MicrophoneNoticeKind) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 13))
                .foregroundColor(Theme.Window.textDim)

            VStack(alignment: .leading, spacing: 4) {
                switch kind {
                case .notDetermined:
                    Text("Reed hasn't been given microphone access yet")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.Window.textPrimary)
                    Text("Grant it now, or press the dictation shortcut and Reed will ask.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Window.textDim)

                    Button("Grant Microphone Access") {
                        requestMicrophoneAccess()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(requestingMicrophoneAccess)
                    .padding(.top, 2)

                case .denied:
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
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.Window.inkRaised.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Fires the real system prompt directly — `SettingsView` is UI, so
    /// (unlike `DictationSession`) it's free to call AVFoundation itself
    /// rather than needing a seam. Reloads `microphoneStatus` afterward so
    /// the notice updates (or disappears) the moment the user answers,
    /// without waiting for the window to regain key status.
    private func requestMicrophoneAccess() {
        guard !requestingMicrophoneAccess else { return }
        requestingMicrophoneAccess = true
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            requestingMicrophoneAccess = false
            reload()
        }
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

    private func toggleRow(
        _ title: String, isOn: Binding<Bool>, note: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: isOn)
                .tint(Theme.Window.reed)
                .foregroundColor(Theme.Window.textPrimary)
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Window.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
