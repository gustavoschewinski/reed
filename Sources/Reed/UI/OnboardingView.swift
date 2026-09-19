import AppKit
import KeyboardShortcuts
import SwiftUI

/// Reed's first-run flow: permissions, then the one-time model
/// download, then the hotkey — in that order, on purpose. The model has to
/// be ready before the hotkey step even appears, which is what keeps
/// recording impossible until it actually is (see `OnboardingModel`'s doc
/// comment).
///
/// A window, not a panel — it follows system light/dark appearance like the
/// main window (`Theme.Window`), not the overlay's permanently-dark tokens.
/// Three quiet screens, no accent colour, no illustrations, no marketing
/// copy. Like the main window, this is ink and nothing else: the primary
/// buttons are tinted with `textPrimary` rather than left on the system
/// accent, so the first thing a new user sees is the same monochrome the
/// rest of the app keeps — and so the app's one red object stays the
/// wordmark.
@MainActor
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.step {
                case .permissions:
                    PermissionsStepView(model: model)
                case .model:
                    ModelStepView(model: model)
                case .hotkey:
                    HotkeyStepView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(32)

            stepDots
                .padding(.bottom, 20)
        }
        .frame(width: 480, height: 420)
        .background(Theme.Window.ink)
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                Circle()
                    .fill(step == model.step ? Theme.Window.textPrimary : Theme.Window.inkRaised)
                    .frame(width: 6, height: 6)
            }
        }
    }
}

// MARK: - Step 1: Permissions

private struct PermissionsStepView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Two permissions")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Theme.Window.textPrimary)
                Text("Reed needs both to work. Grant them here, or handle it later — Settings will show you what's still missing.")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.Window.textDim)
            }

            VStack(spacing: 14) {
                PermissionRow(
                    symbol: "mic.fill",
                    title: "Microphone",
                    detail: "So Reed can hear you.",
                    granted: model.microphoneStatus == .granted,
                    actionTitle: model.microphoneStatus == .denied
                        ? "Open System Settings" : "Allow Microphone",
                    action: {
                        if model.microphoneStatus == .denied {
                            SystemSettings.open(.microphone)
                        } else {
                            model.requestMicrophone()
                        }
                    }
                )

                // Accessibility has no three-state status the way the
                // microphone does — `AXIsProcessTrustedWithOptions` only
                // ever shows its consent alert once per app, then silently
                // no-ops on every later call. So this button doesn't try to
                // guess whether the prompt will fire again: it attempts the
                // prompt AND opens System Settings' Accessibility pane
                // directly, every tap, guaranteeing a working route out
                // regardless of the alert's state. Without this, a user who
                // dismisses the one-time alert without reading it has no
                // way back in.
                PermissionRow(
                    symbol: "keyboard",
                    title: "Accessibility",
                    detail: "So Reed can type into whatever app you're using.",
                    granted: model.accessibilityGranted,
                    actionTitle: "Open System Settings",
                    action: model.openAccessibilitySettings
                )
            }

            Spacer()

            HStack {
                Spacer()
                Button("Continue") { model.advanceToModelStep() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Window.textPrimary)
            }
        }
        .onAppear { model.beginObservingPermissions() }
        .onDisappear { model.stopObservingPermissions() }
        // Polling alone can take up to `pollInterval` to notice a change;
        // this catches it the instant the user comes back from System
        // Settings, without requiring a restart.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
    }
}

private struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let granted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundColor(Theme.Window.textDim)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.Window.textPrimary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.Window.textDim)
            }

            Spacer()

            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.Window.textPrimary)
                    .labelStyle(.titleAndIcon)
            } else {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(Theme.Window.inkRaised)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Step 2: Model

private struct ModelStepView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("The speech model")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Theme.Window.textPrimary)
                Text(
                    "Reed transcribes everything on this Mac — nothing you say ever leaves it. "
                        + "The first time, that means downloading about 600 MB. It happens once."
                )
                .font(.system(size: 13))
                .foregroundColor(Theme.Window.textDim)
            }

            content

            Spacer()

            HStack {
                Spacer()
                trailingButton
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.modelState {
        case .notStarted:
            EmptyView()

        case .working(let progress):
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: progress.fractionCompleted)
                    .tint(Theme.Window.textPrimary)
                Text(caption(for: progress.phase))
                    .font(.system(size: 12))
                    .foregroundColor(Theme.Window.textDim)
            }

        case .ready:
            Label("Ready.", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.Window.textPrimary)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text("That didn't work.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.Window.textPrimary)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.Window.textDim)
            }
        }
    }

    @ViewBuilder
    private var trailingButton: some View {
        switch model.modelState {
        case .notStarted:
            Button("Download the model") { model.startModelDownload() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Window.textPrimary)

        case .working:
            Button("Continue") {}
                .buttonStyle(.borderedProminent)
                .tint(Theme.Window.textPrimary)
                .disabled(true)

        case .ready:
            Button("Continue") { model.advanceToHotkeyStep() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Window.textPrimary)

        case .failed:
            Button("Try again") { model.startModelDownload() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Window.textPrimary)
        }
    }

    /// The 17.7s Neural Engine compile after the download finishes is a
    /// long silent gap on its own — this is what covers it with an honest
    /// message instead of letting the screen look frozen. The progress bar
    /// above still moves on real data throughout; this caption just names
    /// what's actually happening in each phase.
    private func caption(for phase: ModelDownloadProgress.Phase) -> String {
        switch phase {
        case .listing:
            return "Connecting…"
        case .downloading:
            return "Downloading the model…"
        case .compiling:
            return "Preparing the model for your Mac's Neural Engine — about 20 seconds, once only."
        }
    }
}

// MARK: - Step 3: Hotkey

private struct HotkeyStepView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your shortcut")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Theme.Window.textPrimary)
                Text(
                    "A quick tap starts and stops recording. Hold it down to record only "
                        + "while you're holding it."
                )
                .font(.system(size: 13))
                .foregroundColor(Theme.Window.textDim)
            }

            HStack {
                Text("Dictation shortcut")
                    .foregroundColor(Theme.Window.textPrimary)
                Spacer()
                KeyboardShortcuts.Recorder(for: .dictate)
            }
            .padding(14)
            .background(Theme.Window.inkRaised)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text("Change it anytime from Settings.")
                .font(.system(size: 12))
                .foregroundColor(Theme.Window.textDim)

            Spacer()

            HStack {
                Spacer()
                Button("Get started") { model.completeOnboarding() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Window.textPrimary)
            }
        }
    }
}

// MARK: - System Settings deep links

enum SystemSettingsPane {
    case microphone
    case accessibility
}

enum SystemSettings {
    static func open(_ pane: SystemSettingsPane) {
        let urlString: String
        switch pane {
        case .microphone:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        }
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
