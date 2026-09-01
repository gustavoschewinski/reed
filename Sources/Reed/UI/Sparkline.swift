import SwiftUI

/// A hairline sparkline: texture showing rhythm across a trailing window of
/// days, not a chart meant to be read precisely. No axes, no gridlines, no
/// data labels, no fill — a single 1pt stroke.
struct Sparkline: View {
    let values: [Int]
    var color: Color = Theme.reed

    var body: some View {
        GeometryReader { proxy in
            let maxValue = max(values.max() ?? 0, 1)
            let stepX = values.count > 1 ? proxy.size.width / CGFloat(values.count - 1) : 0

            Path { path in
                for (index, value) in values.enumerated() {
                    let x = stepX * CGFloat(index)
                    let y = proxy.size.height * (1 - CGFloat(value) / CGFloat(maxValue))
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        }
    }
}
