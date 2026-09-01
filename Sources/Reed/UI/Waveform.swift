import SwiftUI

/// A rolling strip of level bars, like a tuner's meter — not a mirrored
/// oscilloscope. A reed beats against a mouthpiece; it does not swing
/// symmetrically about a centre line, so every bar grows up from a shared
/// baseline and warms from `textDim` toward `reed` only near its peak.
///
/// `DictationSession` publishes only the instantaneous `level`, not a
/// history, so the rolling window lives here: each new value shifts in from
/// the right and the oldest drops off the left.
@MainActor
struct Waveform: View {
    @ObservedObject var session: DictationSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 2
    private let maxHeight: CGFloat = 22
    /// Silence must still read as "listening", not "frozen" — bars never
    /// collapse to nothing.
    private let minHeight: CGFloat = 3

    @State private var levels: [Float] = Array(repeating: 0, count: 24)

    var body: some View {
        HStack(alignment: .bottom, spacing: barSpacing) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(color(for: level))
                    .frame(width: barWidth, height: height(for: level))
            }
        }
        .frame(height: maxHeight, alignment: .bottom)
        .onReceive(session.$level) { newLevel in
            guard !levels.isEmpty else { return }
            levels.removeFirst()
            levels.append(newLevel)
        }
        .animation(reduceMotion ? nil : Theme.waveformSpring, value: levels)
    }

    private func height(for level: Float) -> CGFloat {
        let normalized = CGFloat(min(max(level, 0), 1))
        return max(minHeight, normalized * maxHeight)
    }

    /// Bars sit at rest colour until they approach the top of their range,
    /// then warm toward `reed` — "at peak only", not across the whole scale.
    private func color(for level: Float) -> Color {
        let normalized = Double(min(max(level, 0), 1))
        let warmth = max(0, (normalized - 0.55) / 0.45)
        return Color.lerp(Theme.textDim, Theme.reed, warmth)
    }
}
