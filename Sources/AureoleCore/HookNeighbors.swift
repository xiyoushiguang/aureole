import Foundation

/// Other tools' hooks on the same events as ours. Two apps that both answer permission prompts, or both
/// announce finished turns, make every alert arrive twice; the settings say so instead of silently stacking up.
public enum HookNeighbors {
    /// Events where a second handler is likely to double up with ours.
    public static let watched = ["PermissionRequest", "Notification", "Stop", "PreToolUse"]

    /// Commands of other handlers on those events, one per distinct program, shortened for display.
    public static func find(settings: [String: Any], events: [String] = watched) -> [String] {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        var out: [String] = []
        for event in events {
            for entry in hooks[event] as? [[String: Any]] ?? [] {
                for h in entry["hooks"] as? [[String: Any]] ?? [] {
                    guard let cmd = h["command"] as? String, !cmd.contains(HookInstaller.marker) else { continue }
                    let name = program(cmd)
                    if !out.contains(name) { out.append(name) }
                }
            }
        }
        return out
    }

    /// "/Applications/Agent HUD.app/Contents/MacOS/agenthud-hook --x" → "agenthud-hook".
    static func program(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        let path: String
        if trimmed.hasPrefix("\""), let end = trimmed.dropFirst().firstIndex(of: "\"") {
            path = String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
        } else {
            path = String(trimmed.split(separator: " ").first ?? "")
        }
        let base = (path as NSString).lastPathComponent
        // Interpreters say little; name the script they run instead.
        if ["node", "python3", "python", "bash", "sh", "zsh", "bun", "deno", "npx"].contains(base) {
            let rest = trimmed.split(separator: " ").dropFirst().first { !$0.hasPrefix("-") }
            if let r = rest { return base + " " + (String(r) as NSString).lastPathComponent }
        }
        return base.isEmpty ? String(trimmed.prefix(40)) : base
    }
}
