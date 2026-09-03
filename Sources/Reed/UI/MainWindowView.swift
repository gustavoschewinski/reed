import AVFoundation
import AppKit
import KeyboardShortcuts
import SwiftUI

/// The main window's three tabs.
enum MainTab: Hashable, CaseIterable {
    case dashboard, history, settings

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: return "chart.bar"
        case .history: return "clock"
        case .settings: return "gearshape"
        }
    }
}

/// Which tab the main window should show. Owned by `AppDelegate` so the
/// "Settings" menu item can jump straight to that tab instead of always
/// opening on the dashboard.
@MainActor
final class MainWindowState: ObservableObject {
    @Published var selectedTab: MainTab = .dashboard
}

/// Root content of the main window (Task 13): Dashboard, History, and
/// Settings behind a sidebar. Unlike the overlay, this follows the system
/// light/dark appearance — see `Theme.Window`.
///
/// The sidebar is hand-built rather than a `List` with `.listStyle(.sidebar)`.
/// The system style paints the selected row in whatever accent colour the
/// user set in System Settings, which would drop an arbitrary, un-designed
/// hue into a window that is otherwise entirely ink and one red wordmark.
/// The rows below select with an ink marker and a shift from dim to
/// primary text instead — quieter, and identical on every Mac.
@MainActor
struct MainWindowView: View {
    @ObservedObject var store: TranscriptStore
    @ObservedObject var settings: Settings
    @ObservedObject var state: MainWindowState

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 520)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The window's only colour, now carried by the app's own icon
            // rather than by a symbol tinted with `mark`. The two reds are
            // the same family but not the same value — the icon's is a lit
            // gradient (around 8B0C12 in its body), `mark` is flat D70015 —
            // so the wordmark keeps `mark` rather than trying to match a
            // colour that changes across the icon's own surface.
            HStack(spacing: Theme.Space.sm) {
                AppIcon(size: 18)
                Text("Reed")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.Window.mark)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Reed")
            .padding(.horizontal, Theme.Space.lg)
            .padding(.bottom, Theme.Space.lg)

            ForEach(MainTab.allCases, id: \.self) { tab in
                SidebarItem(
                    tab: tab,
                    isSelected: state.selectedTab == tab,
                    select: { state.selectedTab = tab }
                )
            }

            Spacer(minLength: Theme.Space.xl)

            StatusFooter()
        }
        .padding(.vertical, Theme.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .windowSurface(.sidebar)
    }

    // MARK: - Detail

    /// Every tab gets the same frame: a title, a hairline, then its own
    /// content. Putting the title here rather than in the window's titlebar
    /// keeps it on the type scale in `Theme.Typography` — a titlebar string
    /// would be sized by AppKit, and it would sit above the sidebar divider
    /// instead of beside it.
    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(state.selectedTab.title)
                    .font(Theme.Typography.title)
                    .foregroundColor(Theme.Window.textPrimary)
                Spacer()
            }
            .padding(.horizontal, Theme.Space.xxl)
            .padding(.bottom, Theme.Space.md)

            Rule()

            Group {
                switch state.selectedTab {
                case .dashboard: DashboardView(store: store)
                case .history: HistoryView(store: store)
                case .settings: SettingsView(settings: settings)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.top, Theme.Space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .windowSurface(.underWindowBackground)
    }
}

// MARK: - Sidebar item

@MainActor
private struct SidebarItem: View {
    let tab: MainTab
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: Theme.Space.sm) {
                // The selection marker: 2pt of full-strength ink against
                // the dim text of every unselected row.
                Theme.Window.textPrimary
                    .frame(width: 2, height: 16)
                    .opacity(isSelected ? 1 : 0)

                Image(systemName: tab.systemImage)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(tab.title)
                    .font(Theme.Typography.sidebarItem)
                Spacer(minLength: 0)
            }
            .foregroundColor(isSelected ? Theme.Window.textPrimary : Theme.Window.textDim)
            .padding(.vertical, Theme.Space.sm)
            .padding(.trailing, Theme.Space.md)
            // The marker occupies the leading gutter, so the row's own
            // leading padding is what's left of the sidebar inset.
            .padding(.leading, Theme.Space.md)
            .background {
                Rectangle()
                    .fill(isHovered && !isSelected ? Theme.Window.hover : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Status footer

/// The bottom of the sidebar: the dictation shortcut, and whether Reed can
/// actually do anything with it.
///
/// This is the sidebar's reason to exist rather than being a nav strip.
/// The two ways dictation silently fails — no microphone, no Accessibility
/// — are otherwise invisible until you press the shortcut and nothing
/// happens, and both are named here in the terms of what breaks ("Reed
/// can't hear you", "Clipboard only") rather than as permission names.
@MainActor
private struct StatusFooter: View {
    @State private var shortcutLabel = StatusFooter.currentShortcutLabel
    @State private var microphoneStatus: AVAuthorizationStatus = .authorized
    @State private var accessibilityGranted = true

    private enum Status {
        case ready
        /// No microphone: dictation records nothing at all.
        case deaf
        /// No Accessibility: dictation works, but the text lands on the
        /// clipboard instead of in the focused app.
        case clipboardOnly

        var label: String {
            switch self {
            case .ready: return "Ready"
            case .deaf: return "Reed can't hear you"
            case .clipboardOnly: return "Clipboard only"
            }
        }

        /// `live` is Reed's one alarm colour, so it's spent on the one
        /// state where dictation produces nothing. A missing Accessibility
        /// permission still transcribes — it's a downgrade, not a failure,
        /// and it stays dim.
        var tint: Color {
            switch self {
            case .deaf: return Theme.Window.live
            case .ready, .clipboardOnly: return Theme.Window.textDim
            }
        }
    }

    private var status: Status {
        if microphoneStatus != .authorized { return .deaf }
        if !accessibilityGranted { return .clipboardOnly }
        return .ready
    }

    /// Read through a static rather than computed inline, so the same
    /// expression seeds `@State` and refreshes it below.
    private static var currentShortcutLabel: String {
        KeyboardShortcuts.getShortcut(for: .dictate)?.description ?? "Not set"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Rule()
                .padding(.bottom, Theme.Space.xs)

            Text(shortcutLabel)
                .font(Theme.Typography.data)
                .foregroundColor(Theme.Window.textPrimary)

            HStack(spacing: Theme.Space.sm) {
                Circle()
                    .fill(status.tint)
                    .frame(width: 6, height: 6)
                Text(status.label)
                    .font(Theme.Typography.caption)
                    .foregroundColor(Theme.Window.textDim)
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            reload()
        }
        // Recording a new shortcut happens in the Settings tab, with this
        // footer visible right next to it — waiting for the window to
        // regain key status would leave the two disagreeing on screen at
        // the same time.
        .onReceive(NotificationCenter.default.publisher(for: .reedShortcutDidChange)) { _ in
            shortcutLabel = Self.currentShortcutLabel
        }
    }

    private func reload() {
        shortcutLabel = Self.currentShortcutLabel
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibilityGranted = TextDelivery.accessibilityGranted
    }
}
