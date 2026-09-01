import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    /// The integration point for every piece in `Core`/`System`/`Data` — see
    /// its own doc comment. It never touches AppKit; this delegate is what
    /// bridges its published `state` to the overlay.
    private let session = AppDelegate.makeDictationSession()
    private let overlay = OverlayPanel()
    private let hotkeyMonitor = HotkeyMonitor()
    private var stateObservation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "Reed"
        )

        let menu = NSMenu()
        menu.addItem(
            withTitle: "Quit Reed",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        item.menu = menu

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

    /// Builds the production `DictationSession` with every real
    /// hardware-backed dependency. A static factory (rather than inline
    /// property initializers) so the throwing `TranscriptStore` init gets a
    /// proper fallback instead of `try!` crashing launch over a corrupt
    /// store on disk.
    private static func makeDictationSession() -> DictationSession {
        let settings = Settings()

        let store: TranscriptStore
        do {
            store = try TranscriptStore()
        } catch {
            NSLog(
                "Reed: failed to open the transcript store (%@); "
                    + "falling back to an in-memory store for this launch",
                String(describing: error))
            // An in-memory `ModelContainer` has nothing on disk that could
            // make its own init throw for the same reason, so this is safe.
            // swiftlint:disable:next force_try
            store = try! TranscriptStore(inMemory: true)
        }

        return DictationSession(
            recorder: Recorder(),
            transcriber: StreamingTranscriber(transcriber: ParakeetTranscriber()),
            volumeControl: SystemAudio(),
            mediaControl: MediaKeyControl(),
            store: store,
            settings: settings
        )
    }
}
