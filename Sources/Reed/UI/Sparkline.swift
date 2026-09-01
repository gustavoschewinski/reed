import SwiftUI

/// A hairline sparkline: texture showing rhythm across a trailing window of
/// days, not a chart meant to be read precisely. No axes, no gridlines, no
/// data labels, no fill — a single 1pt stroke.
///
/// Two marks are allowed beyond that stroke, and both carry information
/// rather than decorating it: a baseline, so a run of silent days reads as
/// resting on zero instead of floating, and a dot on the final point, so
/// "today" is findable without counting from the left. There is
/// deliberately no gradient under the line — a filled area would claim the
/// space between the points means something, and at one value per day it
/// doesn't.
struct Sparkline: View {
    let values: [Int]
    var color: Color = Theme.reed

    var body: some View {
        GeometryReader { proxy in
            // The plot is inset by the endpoint dot's radius on every side.
            // Without it the dot on the final point is sliced in half by
            // the trailing edge, and a peak at the maximum loses the top
            // half of its stroke — both of which read as a rendering bug
            // rather than as data.
            let inset: CGFloat = 2
            let plotWidth = max(proxy.size.width - inset * 2, 1)
            let plotHeight = max(proxy.size.height - inset * 2, 1)
            let maxValue = max(values.max() ?? 0, 1)
            let stepX = values.count > 1 ? plotWidth / CGFloat(values.count - 1) : 0
            let points = values.enumerated().map { index, value in
                CGPoint(
                    x: inset + stepX * CGFloat(index),
                    y: inset + plotHeight * (1 - CGFloat(value) / CGFloat(maxValue))
                )
            }

            ZStack(alignment: .topLeading) {
                Theme.Window.hairline
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .bottom)

                Path { path in
                    for (index, point) in points.enumerated() {
                        if index == 0 {
                            path.move(to: point)
                        } else {
                            path.addLine(to: point)
                        }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))

                if let last = points.last {
                    Circle()
                        .fill(color)
                        .frame(width: 4, height: 4)
                        .position(x: last.x, y: last.y)
                }
            }
        }
    }
}
