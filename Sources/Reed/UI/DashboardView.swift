import AppKit
import SwiftUI

/// The main window's first tab.
///
/// Reed's claim is a comparison, not a big asserted figure: you spoke for
/// this long, and typing the same words would have taken that long. So the
/// two measures below the hero are the point — a short ink rule over a
/// long pale one, where the saving is a *length you can see* before it is a
/// number you read. The hero figure names what that gap adds up to; the
/// rules are what make it true rather than asserted.
///
/// They are 4pt rules, not 16pt bars. At bar weight the two lengths read
/// as a chart and invite comparison of their fills; at rule weight they
/// read as measurements, which is what they are. Both are ink — the
/// difference between them is opacity and length, never hue, so the eye
/// compares the one thing that carries meaning here. The 40 words-per-
/// minute assumption behind "typed" is labelled plainly, not buried.
///
/// Below that: quiet supporting figures (words, sessions, streak) and a
/// hairline 30-day sparkline for rhythm, not precision.
@MainActor
struct DashboardView: View {
    @ObservedObject var store: TranscriptStore

    @State private var inputs: [StatsInput] = []
    /// Drives the one animation on this tab: the measures drawing
    /// themselves from zero on first paint. Off under Reduce Motion, where
    /// they simply start at full length.
    @State private var measuresDrawn = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .onAppear {
            reload()
            drawMeasures()
        }
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

    private func drawMeasures() {
        guard !measuresDrawn else { return }
        if reduceMotion {
            measuresDrawn = true
        } else {
            withAnimation(.easeOut(duration: 0.5)) { measuresDrawn = true }
        }
    }

    // MARK: - Empty state

    /// No zeroed-out figures, no empty chart — one line inviting the first
    /// dictation. An empty screen is an invitation to act, not a report
    /// that nothing happened yet.
    private var emptyState: some View {
        EmptyState(
            systemImage: "waveform",
            title: "Press your shortcut and start talking.",
            detail: "What you dictate shows up here."
        )
        .frame(minHeight: 320)
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxl) {
            hero
            measures
            Rule()
            figures
            Rule()
            sparkline
        }
        .padding(.horizontal, Theme.Space.xxl)
        .padding(.vertical, Theme.Space.xl)
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

    /// The largest type in the window, and the whole reason the tab
    /// exists. It gets there on size alone — there is no accent colour to
    /// spend on it.
    private var hero: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("You saved")
                .font(Theme.Typography.caption)
                .foregroundColor(Theme.Window.textDim)
            Text(DurationFormat.short(savedSeconds))
                .font(Theme.Typography.display)
                .foregroundColor(Theme.Window.textPrimary)
        }
    }

    // MARK: - Measures

    private var measures: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            measure(
                title: "Spoke",
                duration: totalSpokenSeconds,
                fraction: spokenFraction,
                tint: Theme.Window.textPrimary
            )
            measure(
                title: "Typing the same words",
                duration: typedSeconds,
                fraction: 1,
                tint: Theme.Window.track
            )
            Text("At 40 words a minute.")
                .font(Theme.Typography.caption)
                .foregroundColor(Theme.Window.textDim)
        }
    }

    private func measure(
        title: String, duration: Double, fraction: CGFloat, tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundColor(Theme.Window.textDim)
                Spacer()
                Text(DurationFormat.short(duration))
                    .font(Theme.Typography.data)
                    .foregroundColor(Theme.Window.textPrimary)
            }
            GeometryReader { proxy in
                Capsule()
                    .fill(tint)
                    // A measure of zero still shows 2pt of itself. A rule
                    // that vanishes entirely reads as a rendering failure,
                    // not as "nothing yet".
                    .frame(
                        width: max(proxy.size.width * fraction * (measuresDrawn ? 1 : 0), 2),
                        height: 4
                    )
            }
            .frame(height: 4)
        }
    }

    // MARK: - Supporting figures

    private var totalWords: Int { inputs.reduce(0) { $0 + $1.wordCount } }
    private var streak: Int { Stats.currentStreak(inputs, now: .now, calendar: calendar) }

    private var figures: some View {
        HStack(alignment: .top, spacing: Theme.Space.xxxl) {
            figure(value: totalWords.formatted(), label: "words")
            figure(value: inputs.count.formatted(), label: "sessions")
            figure(value: streak.formatted(), label: "day streak")
            Spacer(minLength: 0)
        }
    }

    private func figure(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(value)
                .font(Theme.Typography.dataLarge)
                .foregroundColor(Theme.Window.textPrimary)
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundColor(Theme.Window.textDim)
        }
    }

    // MARK: - Sparkline

    private var dailyCounts: [Int] {
        Stats.dailyWordCounts(inputs, days: sparklineDays, now: .now, calendar: calendar)
    }

    private var sparkline: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack {
                GroupLabel("Last 30 days")
                Spacer()
                Text("\(dailyCounts.reduce(0, +).formatted()) words")
                    .font(Theme.Typography.dataSmall)
                    .foregroundColor(Theme.Window.textDim)
            }
            Sparkline(values: dailyCounts, color: Theme.Window.textPrimary)
                .frame(height: 44)
        }
    }
}
