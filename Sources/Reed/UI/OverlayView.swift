import SwiftUI

/// The overlay's content: a rounded dark pill. With no text yet it is just
/// the control row (record indicator, waveform, elapsed time); once
/// `previewText` has anything in it, a transcript block and a divider
/// appear above the control row and the pill grows to fit them.
///
/// The transcript is one continuous run of text, not two paragraphs:
/// `session.confirmedText` and `session.hypothesisText` are concatenated
/// into a single `Text` with per-run colour (`Theme.textPrimary` /
/// `Theme.textDim`), so the reader sees one sentence whose tail is dimmer —
/// and watches the boundary walk rightward as the model commits.
@MainActor
struct OverlayView: View {
    @ObservedObject var session: DictationSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Reports the pill's fitted size up to `OverlayPanel`, which owns the
    /// actual window frame.
    var onHeightChange: (CGFloat) -> Void = { _ in }

    /// `DictationSession` deliberately publishes no timing information —
    /// only `state`, `previewText`, `level` — so the elapsed-time readout
    /// is a local stopwatch, started and cleared off `state` transitions.
    @State private var recordingStartedAt: Date?
    @State private var now: Date = .now
    @State private var appeared = false

    private let pillWidth: CGFloat = 360
    private let transcriptHeight: CGFloat = 62

    var body: some View {
        VStack(spacing: 0) {
            if !session.previewText.isEmpty {
                transcript
                    .transition(.opacity)
                divider
            }
            controlRow
        }
        .frame(width: pillWidth)
        .background(Theme.ink)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .scaleEffect(appeared ? 1 : 0.94, anchor: .bottom)
        .opacity(appeared ? 1 : 0)
        .animation(reduceMotion ? nil : Theme.appearSpring, value: session.previewText.isEmpty)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: OverlayHeightPreferenceKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(OverlayHeightPreferenceKey.self) { onHeightChange($0) }
        .onAppear {
            withAnimation(reduceMotion ? nil : Theme.appearSpring) { appeared = true }
        }
        .onChange(of: session.state) { _, newState in
            switch newState {
            case .recording where recordingStartedAt == nil:
                recordingStartedAt = .now
            case .idle:
                recordingStartedAt = nil
            default:
                break
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { date in
            now = date
        }
    }

    /// Confirmed and hypothesis text as one `Text` value, each run coloured
    /// independently. A single space joins them — matching
    /// `PreviewUpdate.fullText`'s join — only when both halves are
    /// non-empty, so there's never a stray leading/trailing space or a
    /// doubled one at the boundary.
    private var transcriptText: Text {
        let confirmed = session.confirmedText
        let hypothesis = session.hypothesisText
        let separator = (!confirmed.isEmpty && !hypothesis.isEmpty) ? " " : ""

        return Text(confirmed).foregroundColor(Theme.textPrimary)
            + Text(separator)
            + Text(hypothesis).foregroundColor(Theme.textDim)
    }

    private var transcript: some View {
        transcriptText
            .font(Theme.transcriptFont)
            .lineSpacing(Theme.transcriptLineSpacing)
            .lineLimit(3, reservesSpace: false)
            .multilineTextAlignment(.leading)
            .contentTransition(.opacity)
            .animation(reduceMotion ? nil : Theme.settleFade, value: session.previewText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: transcriptHeight, alignment: .bottom)
            .clipped()
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.35),
                        .init(color: .black, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .padding(.horizontal, Theme.paddingHorizontal)
            .padding(.top, Theme.paddingVertical)
            .padding(.bottom, 8)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.inkRaised)
            .frame(height: 1)
            .padding(.horizontal, Theme.paddingHorizontal)
    }

    private var controlRow: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Theme.live)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            Waveform(session: session)

            Spacer(minLength: 8)

            Text(elapsedString)
                .font(Theme.monoFont)
                .monospacedDigit()
                .foregroundColor(Theme.textDim)

            Image(systemName: "mic.fill")
                .font(.system(size: 10))
                .foregroundColor(Theme.textDim)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Theme.paddingHorizontal)
        .padding(.vertical, Theme.paddingVertical)
    }

    private var elapsedString: String {
        guard let recordingStartedAt else { return "0:00" }
        let elapsed = max(0, Int(now.timeIntervalSince(recordingStartedAt)))
        return String(format: "%d:%02d", elapsed / 60, elapsed % 60)
    }
}

private struct OverlayHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
