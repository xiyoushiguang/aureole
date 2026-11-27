import AppKit
import AureoleCore

/// A short report for bug reports: versions, what is installed, provider states and recent errors.
/// Leaves out tokens, prompts, session names and folders.
@MainActor
enum Diagnostics {
    static func report() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var arch = utsname()
        uname(&arch)
        let machine = withUnsafePointer(to: &arch.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
        let settings = (try? HookInstaller.read()) ?? [:]
        let codex = (try? HookInstaller.read(url: HookInstaller.codexHooksURL)) ?? [:]
        let screens = NSScreen.screens.map { s -> String in
            let notch = NotchGeometry.detect(on: s).hasHardwareNotch ? " notch" : ""
            return "\(Int(s.frame.width))×\(Int(s.frame.height))@\(Int(s.backingScaleFactor))x\(notch)"
        }
        var lines = [
            "Aureole \(AureoleInfo.version)",
            "macOS \(os) · \(machine)",
            "Screens: " + screens.joined(separator: ", "),
            "Claude Code hooks: \(HookInstaller.status(settings: settings))",
            "Codex hooks: \(HookInstaller.status(settings: codex, events: HookInstaller.codexEvents))",
            "Status line feed: \(StatuslineInstaller.isInstalled(settings: settings))",
            "Approve from panel: \(UserDefaults.standard.integer(forKey: ApprovalFiles.waitKey)) s",
            "Panel layout: \(UserDefaults.standard.string(forKey: "panelLayout") ?? "horizon"), display: \(UserDefaults.standard.string(forKey: "displayChoice") ?? "notch")",
        ]
        lines.append("")
        lines.append("Recent problems:")
        lines += recentProblems()
        return lines.joined(separator: "\n")
    }

    /// Error lines from the log, without anything that names a session.
    static func recentProblems(limit: Int = 25) -> [String] {
        // The log is moved aside once it fills up; the problems asked about may be in the file before this one.
        let files = [AureoleLog.shared.previousURL, AureoleLog.shared.url]
        let text = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        guard !text.isEmpty else { return ["(no log)"] }
        let keys = ["failed", "rate limited", "error", "not allowed", "timed out", "Too late"]
        let hits = text.split(separator: "\n").filter { line in
            !line.contains("event session") && keys.contains { line.localizedCaseInsensitiveContains($0) }
        }
        // An error message can quote a path; the home folder's path has the account name in it.
        return hits.isEmpty ? ["(none)"] : hits.suffix(limit).map { PrivateText.withoutHome(String($0)) }
    }

    static func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report(), forType: .string)
    }
}
