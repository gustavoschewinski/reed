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

    /// A generous rolling history; the view renders only as many of the
    /// most recent values as fit the width it's given.
    @State private var levels: [Float] = Array(repeating: 0, count: 200)

    var body: some View {
        GeometryReader { proxy in
            let count = max(1, Int((proxy.size.width + barSpacing) / (barWidth + barSpacing)))
            let visible = Array(levels.suffix(count))
            HStack(alignment: .bottom, spacing: barSpacing) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, level in
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(color(for: level))
                        .frame(width: barWidth, height: height(for: level))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
        }
        .frame(maxWidth: .infinity)
        .frame(height: maxHeight)
        .onReceive(session.$level) { newLevel in
            levels.removeFirst()
            levels.append(newLevel)
        }
        .animation(reduceMotion ? nil : Theme.waveformSpring, value: levels)
    }

    /// Raw RMS of speech sits around 0.02–0.1 — mapped linearly it never
    /// clears the 3 pt floor and the meter reads as dead. Perceived
    /// loudness is logarithmic, so normalize on a dB scale instead:
    /// -50 dB (near silence) → 0, -10 dB (loud speech) → 1.
    private func normalized(_ level: Float) -> CGFloat {
        guard level > 0 else { return 0 }
        let dB = 20 * log10(Double(level))
        return CGFloat(min(max((dB + 50) / 40, 0), 1))
    }

    private func height(for level: Float) -> CGFloat {
        max(minHeight, normalized(level) * maxHeight)
    }

    /// Bars sit at rest colour until they approach the top of their range,
    /// then warm toward `reed` — "at peak only", not across the whole scale.
    private func color(for level: Float) -> Color {
        let warmth = max(0, (Double(normalized(level)) - 0.55) / 0.45)
        return Color.lerp(Theme.textDim, Theme.reed, warmth)
    }
}
