import AppKit
import SwiftUI

/// The main window's first tab.
///
/// Reed's claim is a comparison, not a big asserted figure: you spoke for
/// this long, and typing the same words would have taken that long. So the
/// hero here is two horizontal bars (spoken, typed) with the saved
/// difference called out between them — the number falls out of the
/// picture instead of being the picture. The 40 words-per-minute assumption
/// behind "typed" is labelled plainly, not buried.
///
/// Below that: quiet supporting figures (words, sessions, streak) and a
/// hairline 30-day sparkline for rhythm, not precision.
@MainActor
struct DashboardView: View {
    @ObservedObject var store: TranscriptStore

    @State private var inputs: [StatsInput] = []

    private let calendar = Calendar.current
    private let sparklineDays = 30

    var body: some View {
        ScrollView {
            Group {
                if inputs.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Window.ink)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            reload()
        }
        // `store.didChange` — not `objectWillChange` — fires after a
        // mutation has actually landed (see its doc comment), so this is
        // what lets the dashboard update the moment a dictation lands,
        // instead of reading stale data or waiting for the next
        // appear/focus.
        .onReceive(store.didChange) { reload() }
    }

    private func reload() {
        inputs = store.statsInputs()
    }

    // MARK: - Empty state

    /// No zeroed-out tiles, no empty chart — one line inviting the first
    /// dictation. An empty screen is an invitation to act, not a report
    /// that nothing happened yet.
    private var emptyState: some View {
        Text("Press your shortcut and start talking.")
            .font(.system(size: 15))
            .foregroundColor(Theme.Window.textDim)
            .frame(maxWidth: .infinity, minHeight: 320, alignment: .center)
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 40) {
            hero
            figures
            sparkline
        }
        .padding(32)
    }

    // MARK: - Hero

    private var totalSpokenSeconds: Double {
        inputs.reduce(0) { $0 + $1.durationSeconds }
    }

    /// Equal to `sum(typed_i) - sum(spoken_i)` — the same quantity
    /// `Stats.totalTimeSaved` computes per item and sums, just derived here
    /// from the two aggregate bars instead, since duration is linear.
    private var savedSeconds: Double {
        Stats.totalTimeSaved(inputs)
    }

    private var typedSeconds: Double {
        totalSpokenSeconds + savedSeconds
    }

    private var spokenFraction: CGFloat {
        guard typedSeconds > 0 else { return 0 }
        return CGFloat(totalSpokenSeconds / typedSeconds)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            comparisonBar(title: "You spoke", duration: totalSpokenSeconds, fraction: spokenFraction, tint: Theme.Window.reed)

            HStack(spacing: 6) {
                Text("saved")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.Window.textDim)
                Text(DurationFormat.short(savedSeconds))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.Window.reed)
            }
            .padding(.leading, 2)

            comparisonBar(title: "Typing the same words", duration: typedSeconds, fraction: 1, tint: Theme.Window.inkRaised)

            Text("At 40 words a minute.")
                .font(.system(size: 11))
                .foregroundColor(Theme.Window.textDim)
        }
    }

    private func comparisonBar(title: String, duration: Double, fraction: CGFloat, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.Window.textDim)
                Spacer()
                Text(DurationFormat.short(duration))
                    .font(Theme.monoFont)
                    .foregroundColor(Theme.Window.textPrimary)
            }
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(tint)
                    .frame(width: max(proxy.size.width * fraction, 4), height: 16)
            }
            .frame(height: 16)
        }
    }

    // MARK: - Supporting figures

    private var totalWords: Int { inputs.reduce(0) { $0 + $1.wordCount } }
    private var streak: Int { Stats.currentStreak(inputs, now: .now, calendar: calendar) }

    private var figures: some View {
        HStack(spacing: 32) {
            figure(value: "\(totalWords)", label: "words transcribed")
            figure(value: "\(inputs.count)", label: "sessions")
            figure(value: "\(streak)", label: "day streak")
        }
    }

    private func figure(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(Theme.monoFont)
                .foregroundColor(Theme.Window.textPrimary)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Theme.Window.textDim)
        }
    }

    // MARK: - Sparkline

    private var dailyCounts: [Int] {
        Stats.dailyWordCounts(inputs, days: sparklineDays, now: .now, calendar: calendar)
    }

    private var sparkline: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last 30 days")
                .font(.system(size: 11))
                .foregroundColor(Theme.Window.textDim)
            Sparkline(values: dailyCounts, color: Theme.Window.reed)
                .frame(height: 40)
        }
    }
}
