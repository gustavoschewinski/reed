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
    /// Called when the stop control (Item 3) is clicked. `OverlayPanel`
    /// wires this to `session.cancel()` — this view never calls into
    /// `DictationSession` directly, keeping the same one-way dependency
    /// (`OverlayView` → `DictationSession`, never the reverse) every other
    /// piece of this file already has.
    var onCancel: () -> Void = {}
    /// Reports the stop control's own frame, in this view's local
    /// coordinate space, up to `OverlayPanel` — which uses it to position a
    /// small separate click-catching panel exactly over the dot (Item 9:
    /// the main panel ignores mouse events everywhere else, and a window
    /// that ignores mouse events receives no hover/move events either, so
    /// there is no way to carve out one clickable spot from inside a single
    /// ignoring window).
    var onStopControlFrame: (CGRect) -> Void = { _ in }

    /// `DictationSession` deliberately publishes no timing information —
    /// only `state`, `previewText`, `level` — so the elapsed-time readout
    /// is a local stopwatch, started and cleared off `state` transitions.
    @State private var recordingStartedAt: Date?
    @State private var now: Date = .now
    @State private var appeared = false

    /// The transcript's true, unclamped content height — however many lines
    /// (1, 2, 3, or more) the current text actually needs. Measured, not
    /// guessed, via `TranscriptHeightPreferenceKey` below, so the pill grows
    /// exactly one line at a time instead of jumping straight to
    /// `threeLineCap` on the first character.
    @State private var measuredTranscriptHeight: CGFloat = 0
    /// One line's real rendered height at `Theme.transcriptFont` /
    /// `Theme.transcriptLineSpacing`, measured (not computed from font
    /// metrics, which can drift from SwiftUI's own layout) from a hidden
    /// reference `Text` that's always present — see `body`'s background.
    /// The initial value is only a placeholder used for the first frame or
    /// two, before that measurement lands.
    @State private var lineHeight: CGFloat = 21

    private let pillWidth: CGFloat = 360

    /// The transcript never grows past three lines; once content exceeds
    /// this, it clips and fades at the top instead — "the last ~3 lines".
    private var threeLineCap: CGFloat { lineHeight * 3 }
    /// What's actually applied to the transcript's frame: the smaller of
    /// its true content height and the three-line cap. This is what makes
    /// the pill grow line by line and then stop.
    private var transcriptDisplayHeight: CGFloat { min(measuredTranscriptHeight, threeLineCap) }

    var body: some View {
        VStack(spacing: 0) {
            if !session.previewText.isEmpty {
                transcript
                    .transition(.opacity)
                divider
            }
            if let problem = session.problem {
                problemRow(problem)
            } else {
                controlRow
            }
        }
        .frame(width: pillWidth)
        .background(Theme.ink)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .scaleEffect(appeared ? 1 : 0.94, anchor: .bottom)
        .opacity(appeared ? 1 : 0)
        // Two triggers, one animation: the transcript block appearing/
        // disappearing, and it growing line by line — both are motion
        // budget item 1 ("appear and grow"), never a separate animation.
        .animation(reduceMotion ? nil : Theme.appearSpring, value: session.previewText.isEmpty)
        .animation(reduceMotion ? nil : Theme.appearSpring, value: measuredTranscriptHeight)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: OverlayHeightPreferenceKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(OverlayHeightPreferenceKey.self) { onHeightChange($0) }
        .onPreferenceChange(StopControlFramePreferenceKey.self) { onStopControlFrame($0) }
        .coordinateSpace(name: "overlay")
        // A hidden, always-present single-line reference: measures real
        // line height once (font metrics can drift from SwiftUI's own
        // layout engine) so `threeLineCap` reflects actual rendering
        // rather than a guess, and is ready before any text ever appears.
        .background(
            Text("Ag")
                .font(Theme.transcriptFont)
                .lineSpacing(Theme.transcriptLineSpacing)
                .fixedSize()
                .hidden()
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: LineHeightPreferenceKey.self, value: proxy.size.height)
                    }
                )
        )
        .onPreferenceChange(LineHeightPreferenceKey.self) { newValue in
            guard newValue > 0 else { return }
            lineHeight = newValue
        }
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
            .multilineTextAlignment(.leading)
            .contentTransition(.opacity)
            .animation(reduceMotion ? nil : Theme.settleFade, value: session.previewText)
            // No `.lineLimit` here: capping the line count directly would
            // truncate from the *end* (SwiftUI's default `.tail` truncation
            // mode keeps the first N lines), the wrong direction for "the
            // last ~3 lines". Instead this measures the text's true,
            // unclamped height (however many lines it actually needs)...
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: TranscriptHeightPreferenceKey.self, value: proxy.size.height)
                }
            )
            .onPreferenceChange(TranscriptHeightPreferenceKey.self) { measuredTranscriptHeight = $0 }
            // ...and only *here* is that true height clamped to the
            // three-line cap and bottom-aligned, so a transcript under the
            // cap renders at its exact content height (growing line by
            // line) and one over the cap gets its top clipped away,
            // keeping the tail — the most recently settled/spoken text —
            // visible instead of the oldest.
            .frame(height: transcriptDisplayHeight, alignment: .bottom)
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

    /// Replaces `controlRow` while `session.problem` is set (Item 2) — the
    /// overlay is already on screen at the moment of failure, which is
    /// where the explanation belongs. Same row height/padding as
    /// `controlRow` so the pill doesn't jump size just to show it.
    private func problemRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(Theme.live)
                .accessibilityHidden(true)

            Text(message)
                .font(.system(size: 12))
                .foregroundColor(Theme.textDim)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.paddingHorizontal)
        .padding(.vertical, Theme.paddingVertical)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.inkRaised)
            .frame(height: 1)
            .padding(.horizontal, Theme.paddingHorizontal)
    }

    private var controlRow: some View {
        HStack(spacing: 12) {
            // The stop control (Item 3): same 8pt dot, same placement —
            // only now it's an actual button, wired to `cancel()`, so a
            // stalled `finish()` (offline first load, corrupt model cache)
            // has an exit besides Quit. Restyling it is deliberately left
            // for later; making it work is the fix.
            Button(action: onCancel) {
                Circle()
                    .fill(Theme.live)
                    .frame(width: 8, height: 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop dictation")
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: StopControlFramePreferenceKey.self,
                        value: proxy.frame(in: .named("overlay"))
                    )
                }
            )

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

private struct TranscriptHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct LineHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// The stop control's frame, in the pill's own ("overlay"-named)
/// coordinate space — see `onStopControlFrame`'s doc comment above.
private struct StopControlFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}
