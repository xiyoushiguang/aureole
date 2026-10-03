import AppKit
import Combine
import AureoleCore

/// The first-launch scan: which agents are installed, and whether the user runs them in a terminal or in a
/// desktop app. Drives which hooks the guide recommends and what a click on a session can do.
@MainActor
final class AgentScanner: ObservableObject {
    static let shared = AgentScanner()

    @Published private(set) var findings: [ProviderID: AgentFinding] = [:]
    /// Installed terminals that need a word of setup (kitty's remote control, Ghostty's scripting).
    @Published private(set) var terminalsNeedingSetup: [String] = []
    @Published private(set) var scanning = false
    @Published private(set) var scanned = false

    func scan() {
        guard !scanning else { return }
        scanning = true
        Task.detached(priority: .userInitiated) {
            let cli = Self.commandPaths(["claude", "codex"])
            var running: [ProviderID: [String?]] = [:]
            for p in ProcessTree.all() {
                guard let provider = KnownApps.provider(forProcessName: p.name) else { continue }
                // Only sessions a person started: on a terminal, or inside a desktop app that hosts agents.
                // That leaves out helpers such as a browser extension's native host.
                let root = ProcessTree.rootAppBundleId(of: p.pid)
                let hosted = root.map { KnownApps.isTerminal($0) || KnownApps.desktops[$0] != nil } ?? false
                guard hosted || ProcessTree.controllingTTY(of: p.pid) != nil else { continue }
                running[provider, default: []].append(root)
            }
            let home = FileManager.default.homeDirectoryForCurrentUser
            await MainActor.run {
                var out: [ProviderID: AgentFinding] = [:]
                for provider in ProviderID.allCases {
                    var f = AgentFinding(provider: provider)
                    f.cliPath = cli[provider == .claude ? "claude" : "codex"]
                    f.desktopApps = KnownApps.desktops.filter { $0.value.provider == provider }.keys.sorted()
                        .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
                    f.config = FileManager.default.fileExists(atPath: home.appendingPathComponent(provider == .claude ? ".claude" : ".codex").path)
                    f.addRunning(running[provider] ?? [])
                    out[provider] = f
                }
                self.findings = out
                self.terminalsNeedingSetup = ["net.kovidgoyal.kitty", "com.mitchellh.ghostty"]
                    .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
                self.scanning = false
                self.scanned = true
                let summary = out.values.map { "\($0.provider.rawValue): cli=\($0.cliPath != nil) apps=\($0.desktopApps) running=\($0.runningIn)" }
                AureoleLog.shared.log("agent scan: " + summary.sorted().joined(separator: "; "))
            }
        }
    }

    /// Looks the commands up in the user's login shell, since apps start with a bare PATH. Gives up after 5 s.
    nonisolated static func commandPaths(_ names: [String]) -> [String: String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", names.map { "printf '%s=%s\\n' \($0) \"$(command -v \($0))\"" }.joined(separator: "; ")]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [:] }
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); return [:] }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        var found: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[1].hasPrefix("/") { found[parts[0]] = parts[1] }
        }
        return found
    }
}

/// Human names for apps: ours for the ones we know, otherwise Finder's.
enum AppNames {
    static func name(_ bundleId: String) -> String {
        if let n = KnownApps.terminals[bundleId] { return n }
        if let d = KnownApps.desktops[bundleId] { return d.name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleId
    }

    /// What clicking a session does, in words for its button.
    static func jumpLabel(_ s: AgentSession) -> String {
        if s.tty == nil, s.termProgram == nil, let id = s.bundleId, !KnownApps.isTerminal(id) {
            return L10n.f("Switch to %@", name(id))
        }
        return L10n.t("Jump to terminal")
    }
}
