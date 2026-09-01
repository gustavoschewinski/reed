import AppKit
import QuartzCore
import SwiftUI

/// Hosts `OverlayView` in a floating, non-activating panel — the recording
/// pill that appears over whatever the user was already doing.
///
/// It must never take key focus. If it did, the synthetic ⌘V
/// `TextDelivery` sends after a recording would land in the overlay instead
/// of the app the user was dictating into, and dictation would silently do
/// nothing — see `canBecomeKey` below.
@MainActor
final class OverlayPanel: NSPanel {
    /// How far up from the screen's bottom edge the pill's bottom edge
    /// sits, to clear the Dock.
    private static let bottomInset: CGFloat = 120
    private static let pillWidth: CGFloat = 360
    /// Matches the control-row-only pill (no transcript yet), so the first
    /// frame the panel is positioned at is already close to correct instead
    /// of visibly correcting itself a moment later.
    private static let minHeight: CGFloat = 44

    private var contentHeight: CGFloat = OverlayPanel.minHeight
    /// Repositions the pill if the screen layout changes mid-recording (an
    /// external display unplugged, resolution changed, Dock resized) —
    /// registered in `show()`, removed in `hide()` so nothing fires, or even
    /// stays registered, while the panel is off-screen.
    private var screenParametersObserver: NSObjectProtocol?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.pillWidth, height: Self.minHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // `.stationary` beyond what was specified: it keeps the HUD out of
        // Mission Control's window shuffling, which otherwise treats a
        // floating borderless panel as just another window to rearrange.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
    }

    /// Never becomes key — see the type comment.
    override var canBecomeKey: Bool { false }
    /// Belt-and-braces alongside `canBecomeKey`; a panel with no title bar
    /// has no real use for main-window status either.
    override var canBecomeMain: Bool { false }

    /// Shows the pill bottom-centre of the screen that currently has focus.
    /// Position is recomputed every call, never cached — the user may have
    /// moved to a different display since the panel last showed.
    func show(session: DictationSession) {
        if contentView == nil {
            let view = OverlayView(session: session) { [weak self] height in
                self?.resize(toContentHeight: height)
            }
            contentView = NSHostingView(rootView: view)
        }

        positionBottomCenter(height: contentHeight)
        // `orderFrontRegardless`, never `makeKeyAndOrderFront` — showing the
        // panel must not grant it key status.
        orderFrontRegardless()

        if screenParametersObserver == nil {
            screenParametersObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // `queue: .main` guarantees this already runs on the main
                // thread; `assumeIsolated` is the same pattern `Recorder`
                // uses to cross back into MainActor-isolated code from an
                // API that requires a plain `@Sendable` closure.
                MainActor.assumeIsolated {
                    guard let self, self.isVisible else { return }
                    self.positionBottomCenter(height: self.contentHeight)
                }
            }
        }
    }

    func hide() {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
        screenParametersObserver = nil

        orderOut(nil)
        // Dropped rather than reused: the next `show()` should start every
        // piece of per-recording state (the local stopwatch, the waveform's
        // rolling window, the appear animation) fresh.
        contentView = nil
        contentHeight = Self.minHeight
    }

    private func resize(toContentHeight height: CGFloat) {
        guard height > 0, abs(height - contentHeight) > 0.5 else { return }
        contentHeight = max(height, Self.minHeight)
        positionBottomCenter(height: contentHeight)
    }

    /// Recomputed from `NSScreen.main` every call, never cached — covers
    /// both a fresh `show()` (the user may have moved to another display
    /// since the panel last showed) and a mid-recording screen-parameters
    /// change (Finding 4: an external display disconnecting must not leave
    /// the panel parked on a screen that no longer exists).
    private func positionBottomCenter(height: CGFloat) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let screenFrame = screen.frame
        let width = Self.pillWidth
        let x = screenFrame.midX - width / 2
        let y = screenFrame.minY + Self.bottomInset
        let newFrame = NSRect(x: x, y: y, width: width, height: height)

        guard isVisible, !reduceMotionEnabled else {
            setFrame(newFrame, display: true)
            return
        }

        // `Theme.panelGrowDuration` — not AppKit's own undeclared default —
        // so this and the SwiftUI content spring it accompanies are at
        // least stated in one place, even though an `NSWindow` frame can
        // only be driven by Core Animation, never by a SwiftUI `Animation`.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.panelGrowDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(newFrame, display: true)
        }
    }

    private var reduceMotionEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
