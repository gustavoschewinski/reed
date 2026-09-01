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
    /// Global escape monitor (Item 3): `OverlayPanel` can never become key
    /// (see its own doc comment — the synthetic ⌘V a paste depends on would
    /// otherwise land in the overlay instead of the app being dictated
    /// into), so escape can only ever be caught this way, not through the
    /// normal responder chain. `NSEvent.addGlobalMonitorForEvents`, not a
    /// second `KeyboardShortcuts.Name`: a global *monitor* observes an event
    /// without consuming it, so escape still reaches whatever app is
    /// actually focused — closing a dialog there, say — exactly as if Reed
    /// weren't running. A `KeyboardShortcuts`-registered global *hotkey* for
    /// bare Escape would do the opposite: Carbon's `RegisterEventHotKey`
    /// intercepts the key everywhere, unconditionally, which would break
    /// Escape in every other app for as long as Reed is running. A global
    /// monitor needs the same Accessibility trust Reed already asks for to
    /// deliver text (`README`'s "Reed does not need Input Monitoring" stays
    /// true either way) — without it, this simply never fires, and Quit
    /// remains the fallback it always was.
    private var escapeMonitor: Any?

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

    /// Counts how many of Reed's own windows (main, onboarding — never the
    /// overlay, see its own doc comment) are open, so this delegate knows
    /// when to promote the app to `.regular` and when to drop back to
    /// `.accessory`. See `WindowPolicyTracker`'s own doc comment for why
    /// this is necessary at all: an `.accessory` app cannot properly own a
    /// foreground window, and with no Dock icon a window that recedes
    /// behind other apps looks, to the user, exactly like it closed.
    private var windowPolicyTracker = WindowPolicyTracker()

    override init() {
        // Item 1: must run before anything in this launch ever calls
        // `SystemAudio.mute()` (the `session` constructed a few lines down
        // is the only thing that ever does). If the previous run died
        // mid-recording — a crash, a force-quit, a logout — with the
        // output still muted and no `applicationWillTerminate` to catch
        // it, this is what notices and restores it.
        SystemAudio.restoreLeftoverMuteIfNeeded()

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
        // Combined with `$problem` (Item 2): a denied microphone never
        // leaves `.idle` at all (there was never anything to record), so
        // `$state` alone would never fire for it — `$problem` becoming
        // non-nil is what has to trigger showing the overlay in that case.
        stateObservation = session.$state
            .combineLatest(session.$problem)
            .sink { [weak self] state, problem in
                self?.handle(state: state, problem: problem)
            }

        // Item 3: see `escapeMonitor`'s own doc comment.
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }  // kVK_Escape
            guard let self else { return }
            switch self.session.state {
            case .recording, .transcribing: self.session.cancel()
            case .idle, .delivering: break
            }
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
        } else {
            // Onboarding's own model-download screen is the only place that
            // ever called `prepare()` — fine for the very first launch, but
            // every launch after that skipped it entirely. Without this,
            // the first dictation of every session paid the full model
            // load inside the pass loop: the preview froze, `finish()`
            // blocked on the same load, and the pill sat there with an
            // empty transcript and a running timer. `ParakeetTranscriber
            // .prepare()` memoizes on its own, so warming it here is free
            // if a real dictation gets there first anyway.
            warmModel()
        }
    }

    /// Item 1 (ship blocker): the one code path that runs on a normal Quit
    /// — one click from the menu bar, mid-recording, mutes the machine
    /// forever without it. `session.prepareForTermination()` unwinds every
    /// side effect `begin()` may have started (chiefly the output mute)
    /// synchronously, with no attempt to finish a pass or delivery — there
    /// is no time left for that, and nothing here needs to succeed at
    /// transcribing, only at not leaving the Mac silent.
    ///
    /// This does NOT cover a crash, force-quit, or logout: none of those
    /// call `applicationWillTerminate` at all. That case is handled
    /// separately, at the next launch — see `SystemAudio
    /// .restoreLeftoverMuteIfNeeded()`, called before this run's own
    /// `session` (and the `SystemAudio` it owns) can mute anything.
    func applicationWillTerminate(_ notification: Notification) {
        session.prepareForTermination()
    }

    /// Loads the speech model in the background so it's already resident by
    /// the time the user's first hotkey press of this session needs it. A
    /// failure here must not crash launch — and per Item 2, must not vanish
    /// silently either: it's surfaced through `session.problem` the moment
    /// a real dictation actually needs the model and finds it still isn't
    /// ready.
    private func warmModel() {
        Task { [transcriber] in
            do {
                try await transcriber.prepare()
            } catch {
                NSLog("Reed: failed to warm the speech model at launch: %@", String(describing: error))
            }
        }
    }

    /// How long a problem stays on screen once dictation is back to
    /// `.idle`, before the overlay auto-hides — long enough to actually
    /// read a sentence or two, short enough not to sit there forever.
    /// Cancelled the moment anything else happens: a fresh `begin()` (which
    /// also resets `session.problem` to nil) shows the recording pill in
    /// its place immediately, same as any other state change.
    private static let problemDisplayDuration: Duration = .seconds(4)
    private var problemDismissTask: Task<Void, Never>?

    private func handle(state: DictationState, problem: String?) {
        problemDismissTask?.cancel()
        problemDismissTask = nil

        switch state {
        case .idle:
            guard problem != nil else {
                overlay.hide()
                return
            }
            // A denied microphone never leaves `.idle` (see
            // `stateObservation`'s comment) — this is the only path that
            // shows the overlay for it at all, since `.recording` never
            // happens. Every other cause reaches `.idle` normally, with
            // the overlay already showing; this just delays the hide long
            // enough to actually read the message.
            overlay.show(session: session)
            problemDismissTask = Task { [weak self] in
                try? await Task.sleep(for: Self.problemDisplayDuration)
                guard !Task.isCancelled else { return }
                self?.overlay.hide()
            }
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
            title: startDictationTitle, action: #selector(startDictationFromMenu), keyEquivalent: ""
        )
        start.target = self
        // `toggle()` — what this item calls — is a no-op while transcribing
        // or delivering, so the item itself reflects that rather than
        // offering an action that silently does nothing.
        start.isEnabled = session.state == .idle || session.state == .recording
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

    /// `buildMenu()` is rebuilt fresh every time `showMenu()` runs (see its
    /// own comment), so reading `session.state` here at construction time
    /// is always current — no separate observer needed just for the menu.
    private var startDictationTitle: String {
        session.state == .recording ? "Stop Dictation" : "Start Dictation"
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
            // Reopening after a titlebar close (which orders out but never
            // nils `mainWindow` or releases it — see its own doc comment)
            // means the tracker no longer counts it as open; re-track it and
            // restore `.regular` before bringing it forward, same as below.
            if windowPolicyTracker.windowDidOpen(.main) {
                NSApp.setActivationPolicy(.regular)
            }
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

            // Must happen before `makeKeyAndOrderFront` — an `.accessory`
            // app promoted to `.regular` only after ordering the window
            // front does not reliably take focus. See
            // `WindowPolicyTracker`'s doc comment.
            if windowPolicyTracker.windowDidOpen(.main) {
                NSApp.setActivationPolicy(.regular)
            }
            window.makeKeyAndOrderFront(nil)
            mainWindow = window

            // Same notification onboarding's window already observes (see
            // `showOnboardingWindow`) — one mechanism, not two. Unlike
            // onboarding, closing the main window never nils `mainWindow`:
            // this window is reused for the rest of the launch, only ever
            // ordered out and back in.
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.windowDidClose(.main)
                }
            }
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    /// Shared by both of Reed's windows' `willCloseNotification` observers:
    /// drops the app back to `.accessory` exactly when the window that just
    /// closed was the last one open. See `WindowPolicyTracker`.
    private func windowDidClose(_ kind: WindowPolicyTracker.Kind) {
        if windowPolicyTracker.windowDidClose(kind) {
            NSApp.setActivationPolicy(.accessory)
        }
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
            // Same re-tracking as `openMainWindow`'s reopen path: a titlebar
            // close (without finishing onboarding) orders out and stops the
            // permission poll but never nils `onboardingWindow`, so the
            // tracker no longer counts it as open — restore `.regular`
            // before bringing it forward.
            if windowPolicyTracker.windowDidOpen(.onboarding) {
                NSApp.setActivationPolicy(.regular)
            }
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

        // Must happen before `makeKeyAndOrderFront` — see the matching
        // comment in `openMainWindow`.
        if windowPolicyTracker.windowDidOpen(.onboarding) {
            NSApp.setActivationPolicy(.regular)
        }
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
        //
        // The same notification also drives the activation-policy handoff
        // (`windowDidClose`) — one mechanism for both, not two.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self, weak model] _ in
            // `queue: .main` above already guarantees this runs on the main
            // thread; `assumeIsolated` just tells the type system what's
            // already true, the same pattern `Recorder` uses for its own
            // main-queue callback.
            MainActor.assumeIsolated {
                model?.stopObservingPermissions()
                self?.windowDidClose(.onboarding)
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
