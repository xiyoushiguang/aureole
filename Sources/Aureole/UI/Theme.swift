import SwiftUI
import AureoleCore

enum Theme {
    static let claude = Color(red: 0.87, green: 0.49, blue: 0.36)
    static let codex = Color(red: 0.42, green: 0.80, blue: 0.72)
    static let amber = Color(red: 1.00, green: 0.73, blue: 0.32)
    static let red = Color(red: 1.00, green: 0.38, blue: 0.36)
    /// A session finished a task you have not looked at.
    static let done = Color(red: 0.55, green: 0.72, blue: 1.00)
    static let dim = Color.white.opacity(0.42)
    static let faint = Color.white.opacity(0.22)

    static func accent(_ p: ProviderID) -> Color {
        switch p {
        case .claude: return claude
        case .codex: return codex
        }
    }

    /// Colour for a window given how much is used and whether it is ahead of the clock.
    static func state(for window: UsageWindow, accent: Color) -> Color {
        if window.usedPercent >= 95 { return red }
        if window.usedPercent >= 80 { return amber }
        // Ahead of the clock only matters once there is something at stake; early bursts are normal.
        if window.usedPercent >= 35, let delta = window.paceDelta(), delta > 15 { return amber }
        return accent
    }

    static let mono = Font.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit()
}
