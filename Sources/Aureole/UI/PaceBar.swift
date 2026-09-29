import SwiftUI
import AureoleCore

/// Two layers: a faint "clock" layer showing how much of the window has elapsed,
/// and the bright usage layer. Usage ahead of the clock turns amber.
struct PaceBar: View {
    let window: UsageWindow
    let accent: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let used = min(1, max(0, window.usedPercent / 100))
            let elapsed = window.elapsedFraction()
            let color = Theme.state(for: window, accent: accent)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                if let elapsed {
                    Capsule().fill(Color.white.opacity(0.13)).frame(width: max(0, w * elapsed))
                }
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.7), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: used > 0 ? max(height, w * used) : 0)
                    .shadow(color: color.opacity(0.55), radius: 4, y: 0)
                if let elapsed, elapsed > 0.01, elapsed < 0.99 {
                    Rectangle()
                        .fill(Color.white.opacity(0.55))
                        .frame(width: 1.5, height: height + 6)
                        .offset(x: w * elapsed - 0.75)
                }
            }
        }
        .frame(height: height)
    }
}
