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
    /// The stop control's last-reported frame, in this panel's own local
    /// (SwiftUI, top-left-origin) coordinate space — kept so the hotspot
    /// can be repositioned from `positionBottomCenter` too, not only from
    /// `OverlayView`'s own preference callback, since the panel's screen
    /// position can change (a display change, say) without that view's
    /// internal layout changing at all.
    private var stopControlLocalFrame: CGRect = .zero
    /// A small, separate window layered above this one, positioned exactly
    /// over the stop control — see its own doc comment for why a second
    /// window, not a view-level trick, is what "click-through except one
    /// spot" actually requires (Item 9).
    private let stopHotspot = ClickCatcherPanel()

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
        // Item 9: the pill floats over whatever the user was already
        // doing, for the entire length of every dictation — it must not
        // eat clicks meant for the app underneath. `stopHotspot` is the one
        // carved-out exception, layered above and tracking the stop
        // control's own measured frame.
        ignoresMouseEvents = true
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
        stopHotspot.onClick = { session.cancel() }

        if contentView == nil {
            let view = OverlayView(
                session: session,
                onHeightChange: { [weak self] height in
                    self?.resize(toContentHeight: height)
                },
                onCancel: { session.cancel() },
                onStopControlFrame: { [weak self] frame in
                    self?.stopControlLocalFrame = frame
                    self?.positionStopHotspot()
                }
            )
            contentView = NSHostingView(rootView: view)
        }

        positionBottomCenter(height: contentHeight)
        // `orderFrontRegardless`, never `makeKeyAndOrderFront` — showing the
        // panel must not grant it key status.
        orderFrontRegardless()
        // A child window (rather than a bare `orderFront`) so it always
        // stays layered directly above this panel and is ordered out
        // automatically if this panel ever is, without a second lifecycle
        // to keep in sync by hand.
        addChildWindow(stopHotspot, ordered: .above)
        stopHotspot.orderFrontRegardless()
        positionStopHotspot()

        DebugLog.log(
            "OverlayPanel.show() frame=\(frame) isVisible=\(isVisible) screens=\(NSScreen.screens.count)")

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
        stopHotspot.orderOut(nil)
        // Dropped rather than reused: the next `show()` should start every
        // piece of per-recording state (the local stopwatch, the waveform's
        // rolling window, the appear animation) fresh.
        contentView = nil
        contentHeight = Self.minHeight
        stopControlLocalFrame = .zero

        DebugLog.log(
            "OverlayPanel.hide() frame=\(frame) isVisible=\(isVisible) screens=\(NSScreen.screens.count)")
    }

    private func resize(toContentHeight height: CGFloat) {
        guard height > 0, abs(height - contentHeight) > 0.5 else { return }
        contentHeight = max(height, Self.minHeight)
        positionBottomCenter(height: contentHeight)
    }

    /// Moves `stopHotspot` to sit exactly over the stop control's last
    /// measured frame, converted from SwiftUI's top-left-origin local space
    /// into this panel's current screen-space frame (AppKit's bottom-left
    /// origin) — called both when that measurement changes and whenever
    /// this panel's own frame moves, since a frame move alone doesn't imply
    /// `OverlayView`'s internal layout (and so its preference) changed.
    private func positionStopHotspot() {
        guard stopControlLocalFrame.width > 0, stopControlLocalFrame.height > 0 else { return }
        let panelFrame = frame
        let x = panelFrame.minX + stopControlLocalFrame.minX
        let y = panelFrame.minY + (panelFrame.height - stopControlLocalFrame.maxY)
        stopHotspot.setFrame(
            NSRect(x: x, y: y, width: stopControlLocalFrame.width, height: stopControlLocalFrame.height),
            display: true
        )
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
            // Not animated, so there's no frame-in-flight to keep the
            // hotspot in step with — safe to reposition it immediately
            // against this panel's now-final frame.
            positionStopHotspot()
            return
        }

        // `Theme.panelGrowDuration` — not AppKit's own undeclared default —
        // so this and the SwiftUI content spring it accompanies are at
        // least stated in one place, even though an `NSWindow` frame can
        // only be driven by Core Animation, never by a SwiftUI `Animation`.
        //
        // `stopHotspot` animates in the same group, off the same `frame`
        // this panel is animating toward — computed with `newFrame` here
        // rather than by re-reading `self.frame` inside
        // `positionStopHotspot()`, which mid-animation would only see
        // whatever frame this panel happens to be at on that tick, not
        // where it's headed.
        NSAnimationContext.runAnimationGroup { [weak self] context in
            guard let self else { return }
            context.duration = Theme.panelGrowDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(newFrame, display: true)
            if stopControlLocalFrame.width > 0, stopControlLocalFrame.height > 0 {
                let hotspotFrame = NSRect(
                    x: newFrame.minX + stopControlLocalFrame.minX,
                    y: newFrame.minY + (newFrame.height - stopControlLocalFrame.maxY),
                    width: stopControlLocalFrame.width,
                    height: stopControlLocalFrame.height
                )
                stopHotspot.animator().setFrame(hotspotFrame, display: true)
            }
        }
    }

    private var reduceMotionEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// A tiny, otherwise-invisible window that DOES accept mouse events,
/// layered directly above `OverlayPanel` and kept positioned exactly over
/// its stop control (see `OverlayPanel.positionStopHotspot()`).
///
/// Why a second window at all: `NSWindow.ignoresMouseEvents` is a
/// window-wide, WindowServer-enforced flag — when it's `true`, the window
/// receives no mouse events whatsoever, full stop, and they fall through to
/// whatever's beneath it. There is no equivalent per-VIEW opt-back-in:
/// making one subview's `hitTest` respond while its window still ignores
/// events does nothing, because the window is never asked to hit-test in
/// the first place. A second, small window that does NOT ignore mouse
/// events — placed only over the one interactive spot — is what actually
/// achieves "click-through everywhere except here" (Item 9).
@MainActor
private final class ClickCatcherPanel: NSPanel {
    var onClick: (() -> Void)?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        contentView = ClickCatcherView { [weak self] in self?.onClick?() }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ClickCatcherView: NSView {
    private let onClick: () -> Void

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ClickCatcherView does not support NSCoding")
    }

    override func mouseDown(with event: NSEvent) {
        onClick()
    }
}
