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
/// Every row is a `Field`: name on the left, control on the right,
/// explanation underneath. Groups are separated by space and a `GroupLabel`
/// rather than being boxed — see `Surfaces.swift` for why this window has
/// no cards.
///
/// `accessibilityNotice` below is not a seventh control — it's a
/// conditional problem indicator, shown only while Accessibility isn't
/// granted, and it's the one route back for someone who dismissed
/// onboarding's one-time consent alert without granting it (see
/// `OnboardingModel.openAccessibilitySettings()`'s doc comment for why that
/// alert can't just be re-shown). Preferences are things the user sets;
/// this is Reed telling the user something is wrong, so it stays visually
/// quieter than the six controls — outlined rather than filled, and a
/// plain `.bordered` button rather than a prominent one.
@MainActor
struct SettingsView: View {
    @ObservedObject var settings: Settings

    @State private var devices: [AudioInputDevice] = []
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var accessibilityGranted = TextDelivery.accessibilityGranted
    @State private var microphoneStatus: AVAuthorizationStatus = .authorized
    @State private var requestingMicrophoneAccess = false

    /// Pickers are given a fixed width so the two of them line up down the
    /// right edge instead of each sizing to its own longest option.
    private let controlWidth: CGFloat = 220

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xxl) {
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
                if microphoneNoticeKind != nil || !accessibilityGranted {
                    VStack(alignment: .leading, spacing: Theme.Space.md) {
                        if let microphoneNoticeKind {
                            microphoneNotice(microphoneNoticeKind)
                        }
                        if !accessibilityGranted {
                            accessibilityNotice
                        }
                    }
                }

                group("Shortcut") {
                    Field(title: "Dictation shortcut") {
                        KeyboardShortcuts.Recorder(for: .dictate) { _ in
                            NotificationCenter.default.post(
                                name: .reedShortcutDidChange, object: nil
                            )
                        }
                    }
                    Rule()
                    // Directly under the recorder, not in its own group: it
                    // modifies what the shortcut above does, rather than
                    // being an independent preference.
                    Field(
                        title: "When you press it",
                        note: settings.dictationMode == .automatic
                            ? "A quick press toggles; holding it down talks instead."
                            : nil
                    ) {
                        Picker("", selection: $settings.dictationMode) {
                            Text("Press to start and stop").tag(DictationMode.toggle)
                            Text("Hold to talk").tag(DictationMode.holdToTalk)
                            Text("Automatic").tag(DictationMode.automatic)
                        }
                        .labelsHidden()
                        .accessibilityLabel("When you press it")
                        .frame(width: controlWidth)
                    }
                }

                group("Audio") {
                    Field(title: "Microphone") {
                        Picker("", selection: $settings.inputDeviceID) {
                            Text("System Default").tag(AudioDeviceID?.none)
                            ForEach(devices) { device in
                                Text(device.name).tag(AudioDeviceID?.some(device.id))
                            }
                            // The saved device may not be plugged in right
                            // now. Without an entry for it, no tag in this
                            // Picker would match the current selection —
                            // and on macOS an unmatched selection gets
                            // silently reassigned to the first item,
                            // *writing that back* through the two-way
                            // binding the instant this view renders.
                            // Rendering Settings must never change a stored
                            // setting, so this keeps a (disabled — it can't
                            // be "chosen" again without being plugged back
                            // in) placeholder entry for exactly that ID,
                            // purely so the selection still has somewhere
                            // to match.
                            if let missingDeviceID {
                                Text("Unavailable Microphone")
                                    .tag(AudioDeviceID?.some(missingDeviceID))
                                    .disabled(true)
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel("Microphone")
                        .frame(width: controlWidth)
                    }
                    Rule()
                    Field(title: "Play sounds while recording") {
                        toggle($settings.playSounds, label: "Play sounds while recording")
                    }
                    Rule()
                    Field(title: "Mute other audio while recording") {
                        toggle($settings.muteWhileRecording, label: "Mute other audio while recording")
                    }
                    Rule()
                    Field(
                        title: "Pause media while recording",
                        note: "macOS doesn't tell apps whether media is playing, so this "
                            + "can start something that was paused. Muting already silences "
                            + "playback while you dictate."
                    ) {
                        toggle($settings.pauseMediaWhileRecording, label: "Pause media while recording")
                    }
                }

                group("Startup") {
                    Field(title: "Launch Reed at login") {
                        Toggle("Launch Reed at login", isOn: $launchAtLogin)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(Theme.Window.textPrimary)
                            .onChange(of: launchAtLogin) { _, newValue in
                                LaunchAtLogin.isEnabled = newValue
                            }
                    }
                }
            }
            .padding(.horizontal, Theme.Space.xxl)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // MARK: - Building blocks

    private func group<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupLabel(title)
                .padding(.bottom, Theme.Space.xs)
            content()
        }
    }

    /// The label lives in the `Field` to the left, so the switch itself
    /// carries only an accessibility label — a visible `Toggle` title here
    /// would print the same words twice.
    ///
    /// Tinted with ink rather than left on the system default, which is
    /// the user's chosen accent colour — an arbitrary blue, pink or green
    /// switch would be the loudest thing on a window whose only colour is
    /// the wordmark.
    private func toggle(_ isOn: Binding<Bool>, label: String) -> some View {
        Toggle(label, isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(Theme.Window.textPrimary)
    }

    // MARK: - Notices

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

    /// Mirrors `accessibilityNotice` below — same outlined styling, same
    /// "problem indicator, not a seventh control" treatment. Wording
    /// (and the action offered) differs by `kind`: someone who has never
    /// been asked needs a different sentence, and a different fix, than
    /// someone who said no.
    private func microphoneNotice(_ kind: MicrophoneNoticeKind) -> some View {
        Group {
            switch kind {
            case .notDetermined:
                notice(
                    title: "Reed hasn't been given microphone access yet",
                    detail: "Grant it now, or press the dictation shortcut and Reed will ask.",
                    // Nothing is broken yet — nobody has been asked. This
                    // is the one notice that isn't a failure, so it doesn't
                    // get the alarm colour.
                    isFailure: false,
                    actionTitle: "Grant Microphone Access",
                    action: requestMicrophoneAccess,
                    actionDisabled: requestingMicrophoneAccess
                )
            case .denied:
                notice(
                    title: "Reed can't hear you",
                    detail: "Microphone access is off, so dictation has nothing to transcribe.",
                    isFailure: true,
                    actionTitle: "Open System Settings",
                    action: { SystemSettings.open(.microphone) },
                    actionDisabled: false
                )
            }
        }
    }

    /// Shown only while Accessibility isn't granted — see the type's own
    /// doc comment. Not a failure: dictation still transcribes, the text
    /// just lands on the clipboard, so this stays dim rather than taking
    /// the alarm colour.
    private var accessibilityNotice: some View {
        notice(
            title: "Reed can copy but can't paste",
            detail: "Without Accessibility, dictated text is left on the clipboard "
                + "instead of typed into the app you're using.",
            isFailure: false,
            actionTitle: "Open System Settings",
            action: { SystemSettings.open(.accessibility) },
            actionDisabled: false
        )
    }

    /// Outlined, never filled. A filled banner would be the only solid
    /// surface in the window and would read as more important than the
    /// controls it sits above; the hairline says "read this" without
    /// shouting.
    private func notice(
        title: String,
        detail: String,
        isFailure: Bool,
        actionTitle: String,
        action: @escaping () -> Void,
        actionDisabled: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 13))
                .foregroundColor(isFailure ? Theme.Window.live : Theme.Window.textDim)

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.Window.textPrimary)
                Text(detail)
                    .font(Theme.Typography.caption)
                    .foregroundColor(Theme.Window.textDim)
                    .fixedSize(horizontal: false, vertical: true)

                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(actionDisabled)
                    .padding(.top, Theme.Space.xs)
            }

            Spacer(minLength: 0)
        }
        .padding(Theme.Space.md)
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.Window.hairline, lineWidth: 1)
        }
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
}
