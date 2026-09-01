import SwiftUI

/// Design tokens for Reed's UI: the overlay (Task 12) is the first consumer,
/// but the main window and onboarding (Tasks 13, 14) share these same values
/// rather than each picking their own.
///
/// The overlay is an instrument readout, not a page — something glanced at
/// dozens of times a day and trusted, not admired. The boldness budget here
/// is deliberately tiny: one alarm colour, one accent, and exactly three
/// animations (see the Motion section below).
enum Theme {
    // MARK: - Colors

    /// Pill body. Near-black with a hint of blue-grey — pure black reads as
    /// a hole on macOS.
    static let ink = Color(hex: 0x0E0E10)
    /// Divider, inner surfaces.
    static let inkRaised = Color(hex: 0x1A1A1E)
    /// Confirmed transcript.
    static let textPrimary = Color(hex: 0xF2F2F4)
    /// Hypothesis text, timer, device name.
    static let textDim = Color(hex: 0x8A8A93)
    /// The record indicator. The only alarm colour — used once, nowhere else.
    static let live = Color(hex: 0xFF453A)
    /// Warm brass — waveform bars at peak only.
    static let reed = Color(hex: 0xC9A227)

    // MARK: - Metrics

    static let cornerRadius: CGFloat = 16
    static let paddingHorizontal: CGFloat = 14
    static let paddingVertical: CGFloat = 10

    // MARK: - Type

    /// Transcript body copy: SF Pro Text at 14pt, 1.45 line spacing.
    static let transcriptFont = Font.system(size: 14)
    /// `.lineSpacing()` adds to the font's natural line height rather than
    /// replacing it, so this is the delta needed to reach a ~1.45 multiple
    /// of the 14pt size, not 1.45 * 14 itself.
    static let transcriptLineSpacing: CGFloat = 5

    /// Timer and device name. Monospaced digits are functional, not
    /// stylistic — proportional digits make a running timer jitter every
    /// second as its glyph widths change.
    static let monoFont = Font.system(size: 11, design: .monospaced)

    // MARK: - Motion

    /// Motion budget: exactly three animations, nothing else.
    /// 1. The pill appearing (and growing to fit new content — never a
    ///    fourth, separate animation).
    /// 2. Waveform bars springing to a new height.
    /// 3. Hypothesis text settling into confirmed text.
    /// Respect `accessibilityReduceMotion`: none of these fire under it —
    /// state changes apply straight away instead.
    // MARK: - Window (light/dark)

    /// Tokens for the main window (Dashboard/History/Settings, Task 13+).
    ///
    /// The overlay above is fixed dark on purpose — it floats over whatever
    /// the user was already doing, so it stays legible and consistent no
    /// matter what's under it. The main window is a normal page the user
    /// opens deliberately; a window that stayed dark while the rest of
    /// macOS was in light mode would look broken. So these resolve
    /// dynamically through `NSColor(name:dynamicProvider:)` instead of
    /// picking one fixed value, while keeping the same colour *roles* as
    /// the overlay above: an ink background, a raised surface, primary/dim
    /// text, `live` for the record state, `reed` as the one accent.
    enum Window {
        static let ink = Color.dynamic(light: 0xF7F5F0, dark: 0x0E0E10)
        static let inkRaised = Color.dynamic(light: 0xEAE6DB, dark: 0x1A1A1E)
        static let textPrimary = Color.dynamic(light: 0x1C1C1E, dark: 0xF2F2F4)
        static let textDim = Color.dynamic(light: 0x6B6B70, dark: 0x8A8A93)
        static let live = Color.dynamic(light: 0xD70015, dark: 0xFF453A)
        static let reed = Color.dynamic(light: 0x9C7A1B, dark: 0xC9A227)
    }

    static let appearSpring = Animation.spring(response: 0.18, dampingFraction: 0.82)
    /// `OverlayPanel` grows the actual `NSPanel` frame as the pill's SwiftUI
    /// content grows — still animation 1 (appear-and-grow), but driven by a
    /// second mechanism: AppKit's own `NSAnimationContext`, a different
    /// animation *system* from the SwiftUI spring above (Core Animation's
    /// window-frame resize, not a spring), because `NSWindow` frames aren't
    /// animatable by a SwiftUI `Animation`. Pinning its duration to
    /// `appearSpring`'s `response` here, rather than leaving it at AppKit's
    /// undeclared default, is what keeps the two stated in one place.
    static let panelGrowDuration: TimeInterval = 0.18
    static let waveformSpring = Animation.spring(response: 0.22, dampingFraction: 0.7)
    static let settleFade = Animation.easeInOut(duration: 0.15)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    /// Linear-interpolates two colors in sRGB space. The platform floor is
    /// macOS 14, which predates `Color.mix(with:by:)` (macOS 15) — this
    /// hand-rolls the same idea for the waveform's dim-to-reed warmth.
    static func lerp(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let t = min(max(t, 0), 1)
        let ca = NSColor(a).usingColorSpace(.sRGB) ?? NSColor(a)
        let cb = NSColor(b).usingColorSpace(.sRGB) ?? NSColor(b)
        return Color(
            .sRGB,
            red: ca.redComponent + (cb.redComponent - ca.redComponent) * t,
            green: ca.greenComponent + (cb.greenComponent - ca.greenComponent) * t,
            blue: ca.blueComponent + (cb.blueComponent - ca.blueComponent) * t,
            opacity: 1
        )
    }

    /// A color that resolves to a different fixed hex value depending on
    /// whether it's being drawn in a light or dark effective appearance —
    /// used by `Theme.Window`, never by the always-dark overlay tokens
    /// above. Built on `NSColor(name:dynamicProvider:)` because SwiftUI has
    /// no direct "two hex values, pick by appearance" API of its own.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
