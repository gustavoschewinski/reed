import AppKit
import SwiftUI

/// The main window's shared surface language.
///
/// The window is built out of three things and nothing else: a vibrancy
/// material, hairlines, and space. There is no card — no filled, bordered,
/// shadowed box grouping related controls. Grouping is done by proximity
/// and by `Rule`, which is why the padding constants here are large and
/// the lines are thin. Anything that wants to become a box should become
/// more space instead.
///
/// These types exist so the three tabs share one implementation of that
/// language rather than each re-deriving its own paddings and separators.

// MARK: - Vibrancy

/// An `NSVisualEffectView` as a SwiftUI background.
///
/// `blendingMode: .behindWindow` is the point — it samples and blurs the
/// *desktop* behind the window, which is the real macOS translucency, not
/// a `.opacity()` on a solid fill (that just lets the window's own
/// backdrop show through and looks washed out rather than deep).
///
/// This only works if the window itself is non-opaque with a clear
/// background colour; `AppDelegate` sets that up where the window is
/// built. Without it, AppKit composites the material against the window's
/// own opaque backing and the blur silently does nothing.
struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        // The macOS-native behaviour: vibrancy desaturates when the window
        // isn't key, which is how the user tells a focused window from a
        // background one. Pinning this to `.active` would look more
        // "designed" and read as broken.
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

extension View {
    /// The main window's background: blurred desktop, then the scrim that
    /// makes contrast predictable over it. Always applied as a pair —
    /// applying the material without the scrim leaves every token in
    /// `Theme.Window` at the mercy of the user's wallpaper.
    func windowSurface(_ material: NSVisualEffectView.Material) -> some View {
        background {
            VisualEffect(material: material)
                .overlay(Theme.Window.scrim)
                .ignoresSafeArea()
        }
    }
}

// MARK: - App icon

/// Reed's own icon, at whatever size the call site needs.
///
/// Loads `Reed.icns` out of the bundle rather than a second copy of the
/// artwork added to `Resources/`: the icon in the Dock and the icon in the
/// window are the same file, so they cannot drift, and changing
/// `Resources/icon-source.png` changes both.
///
/// Deliberately not `NSImage(named: .applicationIconName)`, which is the
/// obvious way to ask for it. That goes through the system's icon services,
/// and on macOS 26 those hand back the icon *as the system presents it* —
/// which for an app shipping a plain `.icns` means mounted on Tahoe's light
/// glass tile. In the Dock that tile is the platform's business; inside our
/// own window it is a white box around a 16pt mark. Reading the file gives
/// the artwork, and nothing else.
///
/// The fallback is the waveform symbol the wordmark used before there was
/// an icon. It only appears outside a built `.app` — `swift run`, tests —
/// where there is no bundle resource to read.
struct AppIcon: View {
    var size: CGFloat

    private var icon: NSImage? {
        guard let url = Bundle.main.url(forResource: "Reed", withExtension: "icns") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "waveform")
                .font(.system(size: size * 0.8, weight: .medium))
                .foregroundColor(Theme.Window.mark)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Rule

/// A hairline. The window's only grouping device.
struct Rule: View {
    var inset: CGFloat = 0
    var strong = false

    var body: some View {
        (strong ? Theme.Window.hairlineStrong : Theme.Window.hairline)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

// MARK: - Group label

/// The small dim label naming a set of rows.
///
/// Sentence case, not uppercase with letter-spacing: this window states
/// what things are, it doesn't announce sections. Uppercase eyebrows would
/// add a second voice to a surface that only has room for one.
struct GroupLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Theme.Typography.heading)
            .foregroundColor(Theme.Window.textDim)
    }
}

// MARK: - Field

/// A settings row: what it is on the left, the control on the right, and
/// an optional explanation under both.
///
/// The note sits under the label rather than beside the control because it
/// explains the *setting*, not the switch — and because a second column of
/// prose next to a control makes the eye choose between two reading
/// orders.
struct Field<Control: View>: View {
    let title: String
    var note: String?
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.lg) {
                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundColor(Theme.Window.textPrimary)
                Spacer(minLength: Theme.Space.lg)
                control()
            }
            if let note {
                Text(note)
                    .font(Theme.Typography.caption)
                    .foregroundColor(Theme.Window.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, Theme.Space.xxl)
            }
        }
        .padding(.vertical, Theme.Space.md)
    }
}

// MARK: - Hover

/// Fills a row while the pointer is over it, and reports the state so the
/// row can also reveal its actions.
///
/// The fill is `Theme.Window.hover` — around 5% ink. On glass that is
/// enough to say "this row, this one" and not enough to become a band of
/// colour marching down the list as the pointer moves.
struct HoverHighlight: ViewModifier {
    @Binding var isHovered: Bool
    var radius: CGFloat = Theme.Radius.control
    var inset: CGFloat = Theme.Space.sm

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(isHovered ? Theme.Window.hover : Color.clear)
                    .padding(.horizontal, -inset)
            }
            .onHover { isHovered = $0 }
    }
}

extension View {
    func hoverHighlight(_ isHovered: Binding<Bool>) -> some View {
        modifier(HoverHighlight(isHovered: isHovered))
    }
}

// MARK: - Icon button

/// A borderless glyph button — history's copy and delete.
///
/// `.plain` rather than `.borderless`: borderless still tints the glyph
/// with the system accent colour on macOS, which would put a second accent
/// on a window that has exactly one.
struct IconButton: View {
    let systemName: String
    let help: String
    var tint: Color = Theme.Window.textDim
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundColor(isHovered ? Theme.Window.textPrimary : tint)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

// MARK: - Empty state

/// What a tab shows when it has nothing to show.
///
/// An empty screen is an invitation to act, so the line that tells the
/// user what to do is the primary text and the icon stays dim behind it —
/// never a large decorative glyph with the instruction as a caption under
/// it.
struct EmptyState: View {
    let systemImage: String
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .light))
                .foregroundColor(Theme.Window.textDim.opacity(0.7))
            Text(title)
                .font(Theme.Typography.body)
                .foregroundColor(Theme.Window.textPrimary)
            if let detail {
                Text(detail)
                    .font(Theme.Typography.caption)
                    .foregroundColor(Theme.Window.textDim)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.xxl)
    }
}
