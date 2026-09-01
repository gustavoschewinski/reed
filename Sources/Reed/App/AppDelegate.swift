import AppKit
import AVFoundation
import Combine
import KeyboardShortcuts
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    /// Shared with the main window (Task 13), which is why these two are
    /// now separate stored properties rather than only living inside
    /// `session` — `MainWindowView` needs the same `Settings` and
    /// `TranscriptStore` instances `DictationSession` writes to, not copies.
    private let settings: Settings
    private let store: TranscriptStore

    /// Held separately from `session` (which only sees it through
    /// `StreamingTranscriber`) so onboarding's model-download screen can
    /// call `prepare(progressHandler:)` on the very same actor instance —
    /// warming it once here means the first real dictation never re-pays
    /// that cost. `ParakeetTranscriber.prepare()` memoizes on its own, so
    /// there is no risk of a second, duplicate load either way.
    private let transcriber: ParakeetTranscriber

    /// The integration point for every piece in `Core`/`System`/`Data` — see
    /// its own doc comment. It never touches AppKit; this delegate is what
    /// bridges its published `state` to the overlay.
    private let session: DictationSession
    private let overlay = OverlayPanel()
    private let hotkeyMonitor = HotkeyMonitor()
    private var stateObservation: AnyCancellable?

    /// The Dashboard/History/Settings window (Task 13). Created lazily on
    /// first open and reused after that — `nil` only ever means "never
    /// opened this launch", not "closed".
    private var mainWindow: NSWindow?
    private let mainWindowState = MainWindowState()

    /// First-run onboarding (Task 14). Created lazily, reused while
    /// showing, and cleared once it finishes — `nil` means either "never
    /// shown this launch" or "already completed", both of which are
    /// indistinguishable to anything that only wants to bring it forward.
    private var onboardingWindow: NSWindow?

    override init() {
        let settings = Settings()
        let store = AppDelegate.makeStore()
        let transcriber = ParakeetTranscriber()
        self.settings = settings
        self.store = store
        self.transcriber = transcriber
        self.session = DictationSession(
            recorder: Recorder(),
            transcriber: StreamingTranscriber(transcriber: transcriber),
            volumeControl: SystemAudio(),
            mediaControl: MediaKeyControl(),
            store: store,
            settings: settings
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "Reed"
        )
        // No `item.menu` assigned up front: that would route every click
        // (left and right) straight to the menu, with no way to tell them
        // apart. Instead the button's own action decides, in
        // `handleStatusItemClick`, and the menu is only attached to the
        // item transiently for a right-click — see that method.
        item.button?.target = self
        item.button?.action = #selector(handleStatusItemClick)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        statusItem = item

        // `DictationSession` never touches UI (Ruling 2) — this is the one
        // place that watches its state and shows or hides the overlay.
        stateObservation = session.$state
            .removeDuplicates()
            .sink { [weak self] state in
                self?.handle(state: state)
            }

        hotkeyMonitor.onGesture = { [weak self] gesture in
            guard let self else { return }
            // Recording must be impossible until onboarding — and with it,
            // the model — is ready (see the brief). This is the one path
            // that could reach `session` before that: a shortcut left over
            // from a previous run's `UserDefaults`, fired before this run's
            // onboarding has completed. Rather than let it silently do
            // nothing, bring the onboarding window forward — visible state
            // beats a shortcut that appears to do nothing at all.
            guard settings.hasCompletedOnboarding else {
                showOnboardingWindow()
                return
            }
            switch gesture {
            case .tap: session.toggle()
            case .holdStart: session.begin()
            case .holdEnd: session.end()
            }
        }
        hotkeyMonitor.activate()

        if !settings.hasCompletedOnboarding {
            showOnboardingWindow()
        }
    }

    private func handle(state: DictationState) {
        switch state {
        case .idle:
            overlay.hide()
        case .recording, .transcribing, .delivering:
            overlay.show(session: session)
        }
    }

    // MARK: - Status item

    /// Left-click opens the main window; right-click shows the menu
    /// (Start Dictation, Open Reed, Settings, Quit). `NSApp.currentEvent`
    /// is how a single button action tells the two apart.
    @objc private func handleStatusItemClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showMenu()
        } else {
            openMainWindow()
        }
    }

    private func showMenu() {
        guard let statusItem, let button = statusItem.button else { return }
        statusItem.menu = buildMenu()
        // Attaching the menu and immediately re-triggering the button's own
        // click is the standard way to get `NSStatusItem` to pop up a menu
        // on demand instead of unconditionally on every click; it's removed
        // again right after so a left-click goes back through
        // `handleStatusItemClick` next time instead of always opening it.
        button.performClick(nil)
        statusItem.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let start = NSMenuItem(
            title: "Start Dictation", action: #selector(startDictationFromMenu), keyEquivalent: ""
        )
        start.target = self
        menu.addItem(start)

        let open = NSMenuItem(
            title: "Open Reed", action: #selector(openReedFromMenu), keyEquivalent: ""
        )
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        menu.addItem(
            withTitle: "Quit Reed",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        return menu
    }

    @objc private func startDictationFromMenu() {
        session.toggle()
    }

    @objc private func openReedFromMenu() {
        openMainWindow()
    }

    @objc private func openSettingsFromMenu() {
        openMainWindow(selecting: .settings)
    }

    // MARK: - Main window

    private func openMainWindow(selecting tab: MainTab = .dashboard) {
        mainWindowState.selectedTab = tab

        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Reed"
            window.isReleasedWhenClosed = false
            window.center()
            // Deliberately not set: leaving `window.appearance` nil is what
            // makes it follow the system light/dark appearance, unlike the
            // always-dark overlay — see `Theme.Window`.
            window.contentView = NSHostingView(
                rootView: MainWindowView(store: store, settings: settings, state: mainWindowState)
            )
            window.makeKeyAndOrderFront(nil)
            mainWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Onboarding

    /// Shows the first-run window (Task 14), or just brings it forward if
    /// it's already open. Every system call `OnboardingModel` needs is
    /// wired up here — this is the one place that actually touches
    /// AVFoundation's microphone API, `TextDelivery`'s Accessibility calls,
    /// and `transcriber.prepare(progressHandler:)`, so the model itself
    /// stays free of all three and testable without them.
    private func showOnboardingWindow() {
        if let onboardingWindow {
            onboardingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let model = OnboardingModel(
            requestMicrophoneAccess: {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            },
            currentMicrophoneStatus: {
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: return .granted
                case .denied, .restricted: return .denied
                case .notDetermined: return .notDetermined
                @unknown default: return .notDetermined
                }
            },
            currentAccessibilityGranted: { TextDelivery.accessibilityGranted },
            // macOS shows `AXIsProcessTrustedWithOptions`'s consent alert
            // only once per app; every call after that is a silent no-op.
            // Opening System Settings' Accessibility pane directly here too
            // — every tap, unconditionally — is what guarantees a working
            // route out regardless of whether the alert actually fires,
            // matching the microphone row's always-working escape. See
            // `OnboardingModel.openAccessibilitySettings()`'s doc comment.
            requestAccessibility: {
                TextDelivery.requestAccessibility()
                SystemSettings.open(.accessibility)
            },
            prepareModel: { [transcriber] progressHandler in
                try await transcriber.prepare(progressHandler: progressHandler)
            },
            suggestHotkeyDefault: {
                // Per KeyboardShortcuts' own guidance: don't bake a default
                // into the `Name` declaration (that would steal the
                // shortcut for every user, always) — only pre-fill one here,
                // on the screen that lets the user immediately change it,
                // and only if nothing is set yet.
                guard KeyboardShortcuts.getShortcut(for: .dictate) == nil else { return }
                KeyboardShortcuts.setShortcut(
                    KeyboardShortcuts.Shortcut(.space, modifiers: [.control, .option]),
                    for: .dictate
                )
            },
            finish: { [weak self] in
                self?.settings.hasCompletedOnboarding = true
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
            }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Reed"
        window.isReleasedWhenClosed = false
        window.center()
        // Deliberately not set, same as the main window: leaving
        // `window.appearance` nil is what makes it follow the system
        // light/dark appearance instead of staying fixed like the overlay.
        window.contentView = NSHostingView(rootView: OnboardingView(model: model))
        window.makeKeyAndOrderFront(nil)
        onboardingWindow = window

        // `PermissionsStepView.onDisappear` stops the permission poll when
        // SwiftUI swaps that step's content out, but closing the window
        // from the titlebar orders it out rather than deallocating its
        // content — whether `onDisappear` fires reliably in that case isn't
        // something to rely on. This is the explicit backstop: whatever
        // step the window was on, closing it always stops the poll, so a
        // 750ms timer can never keep ticking for the rest of the app's
        // life. `stopObservingPermissions()` is idempotent, so this is a
        // no-op on the (usual) path where polling was already stopped.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak model] _ in
            // `queue: .main` above already guarantees this runs on the main
            // thread; `assumeIsolated` just tells the type system what's
            // already true, the same pattern `Recorder` uses for its own
            // main-queue callback.
            MainActor.assumeIsolated {
                model?.stopObservingPermissions()
            }
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Store

    /// Opens the on-disk `TranscriptStore`, falling back to an in-memory
    /// one if that throws (a corrupt store on disk must not crash launch).
    private static func makeStore() -> TranscriptStore {
        do {
            return try TranscriptStore()
        } catch {
            NSLog(
                "Reed: failed to open the transcript store (%@); "
                    + "falling back to an in-memory store for this launch",
                String(describing: error))
            // An in-memory `ModelContainer` has nothing on disk that could
            // make its own init throw for the same reason, so this is safe.
            // swiftlint:disable:next force_try
            return try! TranscriptStore(inMemory: true)
        }
    }
}
