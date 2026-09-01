import Foundation

/// Tracks which of Reed's own top-level windows are currently open, so
/// `AppDelegate` knows when to promote the app to `.regular` and when to
/// drop back to `.accessory`.
///
/// The bug this exists to fix: an `.accessory` app (no Dock icon) cannot
/// properly own a foreground window. `makeKeyAndOrderFront` followed by
/// `NSApp.activate` works right up until the app deactivates — then the
/// window drops behind every other app's, and with no Dock icon there is no
/// way to bring it back except the menu bar. To the user that is
/// indistinguishable from the window having closed. The fix is the standard
/// pattern: run `.regular` while any of Reed's own windows are open, and
/// return to `.accessory` the moment the last one closes.
///
/// Deliberately a `Set`, not a counter: each `Kind` names one of Reed's own
/// singleton windows (there is at most one main window and one onboarding
/// window per launch), so bringing an already-open window forward must
/// never double-count it, and closing a window that was never open must
/// never under-count. The overlay panel is not a `Kind` here at all — it is
/// a non-activating floating panel, not one of Reed's "windows" for this
/// purpose. If it were counted, every dictation would put a Dock icon on
/// screen.
struct WindowPolicyTracker {
    enum Kind: Hashable {
        case main
        case onboarding
    }

    private(set) var openWindows: Set<Kind> = []

    /// Call when `kind` is shown — whether newly created or just brought
    /// forward. Returns `true` exactly when this is the transition from no
    /// windows open to one: the moment the caller must switch to
    /// `.regular`, and must do so *before* ordering the window front so it
    /// takes focus properly.
    @discardableResult
    mutating func windowDidOpen(_ kind: Kind) -> Bool {
        let wasEmpty = openWindows.isEmpty
        openWindows.insert(kind)
        return wasEmpty
    }

    /// Call when `kind` closes. Returns `true` exactly when this was the
    /// last open window: the moment the caller must switch back to
    /// `.accessory`. A no-op (returning `false`) if `kind` was not tracked
    /// as open and something else still is.
    @discardableResult
    mutating func windowDidClose(_ kind: Kind) -> Bool {
        openWindows.remove(kind)
        return openWindows.isEmpty
    }
}
