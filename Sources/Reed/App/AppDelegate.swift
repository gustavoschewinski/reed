import AppKit
import Combine
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

    override init() {
        let settings = Settings()
        let store = AppDelegate.makeStore()
        self.settings = settings
        self.store = store
        self.session = DictationSession(
            recorder: Recorder(),
            transcriber: StreamingTranscriber(transcriber: ParakeetTranscriber()),
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
            switch gesture {
            case .tap: session.toggle()
            case .holdStart: session.begin()
            case .holdEnd: session.end()
            }
        }
        hotkeyMonitor.activate()
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
