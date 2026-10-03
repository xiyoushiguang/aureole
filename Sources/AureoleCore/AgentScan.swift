import Foundation

/// Where AI coding agents run on this Mac: which apps are terminals (a click can reach the tab) and which are
/// desktop apps that host the agent themselves (a click can only bring the app forward).
public enum KnownApps {
    public static let terminals: [String: String] = [
        "com.apple.Terminal": "Terminal", "com.googlecode.iterm2": "iTerm2", "com.mitchellh.ghostty": "Ghostty",
        "com.github.wez.wezterm": "WezTerm", "net.kovidgoyal.kitty": "kitty", "dev.warp.Warp-Stable": "Warp",
        "org.alacritty": "Alacritty", "com.microsoft.VSCode": "VS Code", "com.microsoft.VSCodeInsiders": "VS Code Insiders",
        "com.todesktop.230313mzl4w4u92": "Cursor",
    ]
    /// Desktop apps that run an agent inside them, and which agent.
    public static let desktops: [String: (name: String, provider: ProviderID)] = [
        "com.openai.codex": ("Codex", .codex), "com.openai.chat": ("ChatGPT", .codex),
        "com.anthropic.claudefordesktop": ("Claude", .claude),
    ]

    public static func isTerminal(_ bundleId: String?) -> Bool { bundleId.map { terminals[$0] != nil } ?? false }

    /// Kernel process names of the agents' own binaries. Case matters: the Claude desktop app's own process is
    /// "Claude", which is not a Claude Code session; the npm package's native binary runs as "claude.exe".
    public static func provider(forProcessName name: String) -> ProviderID? {
        if name == "claude" || name.hasPrefix("claude.") || name.hasPrefix("claude-code") { return .claude }
        if name == "codex" || name.hasPrefix("codex-") { return .codex }
        return nil
    }
}

/// What the first-launch scan found for one agent.
public struct AgentFinding: Equatable, Sendable {
    public var provider: ProviderID
    /// Path of the command-line tool, when it is on the user's PATH.
    public var cliPath: String?
    /// Bundle ids of installed desktop apps that host this agent.
    public var desktopApps: [String] = []
    /// Bundle ids of the apps running this agent right now (terminals or desktop apps), most frequent first.
    public var runningIn: [String] = []
    public var config: Bool = false

    public init(provider: ProviderID) { self.provider = provider }

    public var installed: Bool { cliPath != nil || !desktopApps.isEmpty || config }
    /// Runs inside a terminal somewhere (so tab-level jumps apply).
    public var usesTerminal: Bool { runningIn.contains(where: KnownApps.isTerminal) || (runningIn.isEmpty && cliPath != nil) }
    /// Runs inside a desktop app somewhere (a click brings that app forward).
    public var usesDesktop: Bool { runningIn.contains { KnownApps.desktops[$0] != nil } || (runningIn.isEmpty && !desktopApps.isEmpty) }

    /// Folds running agent processes (by root app) into the finding.
    public mutating func addRunning(_ bundleIds: [String?]) {
        var counts: [String: Int] = [:]
        for case let id? in bundleIds { counts[id, default: 0] += 1 }
        runningIn = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }
}
