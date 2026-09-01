import SwiftUI

/// The main window's three tabs.
enum MainTab: Hashable {
    case dashboard, history, settings
}

/// Which tab the main window should show. Owned by `AppDelegate` so the
/// "Settings" menu item can jump straight to that tab instead of always
/// opening on the dashboard.
@MainActor
final class MainWindowState: ObservableObject {
    @Published var selectedTab: MainTab = .dashboard
}

/// Root content of the main window (Task 13): Dashboard, History, and
/// Settings behind a tab bar. Unlike the overlay, this follows the system
/// light/dark appearance — see `Theme.Window`.
@MainActor
struct MainWindowView: View {
    @ObservedObject var store: TranscriptStore
    @ObservedObject var settings: Settings
    @ObservedObject var state: MainWindowState

    var body: some View {
        TabView(selection: $state.selectedTab) {
            DashboardView(store: store)
                .tabItem { Label("Dashboard", systemImage: "chart.bar.fill") }
                .tag(MainTab.dashboard)

            HistoryView(store: store)
                .tabItem { Label("History", systemImage: "clock") }
                .tag(MainTab.history)

            SettingsView(settings: settings)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(MainTab.settings)
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}
