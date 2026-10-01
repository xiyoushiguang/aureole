// aureole-hook: a Claude Code hook that records what each session is doing.
// Reads the hook JSON from stdin, folds it into ~/Library/Application Support/Aureole/sessions/<id>.json,
// prints nothing and always exits 0, so it can never block or alter a session.
import Foundation
import Darwin
import AureoleCore

func main() {
    let args = CommandLine.arguments.dropFirst()
    if args.first == "--version" { print(AureoleInfo.version); return }

    // Stdin is small (a few KB); cap it anyway so a runaway tool_input cannot stall the hook.
    let data = FileHandle.standardInput.readData(ofLength: 4 << 20)
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let event = HookEvent(json: obj) else { return }
    // Sub-agent activity belongs to the parent session's turn; only the parent agent changes the state.
    if obj["agent_id"] != nil, event.name != "SubagentStop" { return }

    let now = Date()
    let keepPrompt = UserDefaults(suiteName: "app.aureole.Aureole")?.object(forKey: "sessionPromptPreview") as? Bool ?? true
    let url = SessionFiles.url(for: event.sessionId)
    var session = SessionReducer.apply(event, to: SessionFiles.load(url), now: now, keepPrompt: keepPrompt)
    if session.agentPid == nil || session.tty == nil || event.name == "SessionStart" {
        fillProcessInfo(&session)
    }
    if session.state == .ended {
        try? FileManager.default.removeItem(at: url)
        return
    }
    try? SessionFiles.save(session)
}

/// Finds the agent process above us and the terminal it runs in, for liveness checks and "jump to terminal".
func fillProcessInfo(_ s: inout AgentSession) {
    let env = ProcessInfo.processInfo.environment
    s.termProgram = env["TERM_PROGRAM"]
    s.termSessionId = env["ITERM_SESSION_ID"] ?? env["TERM_SESSION_ID"]
    s.bundleId = env["__CFBundleIdentifier"]
    s.tmuxPane = env["TMUX_PANE"]
    // Walk up from our parent; the CLI shows up as "claude" (the installed binary) or "node".
    var pid = getppid()
    var agent: pid_t = pid
    for _ in 0..<6 {
        guard let info = processInfo(pid) else { break }
        let name = info.name.lowercased()
        if name == "claude" || name == "node" || name.hasPrefix("claude") {
            agent = pid
            break
        }
        if info.ppid <= 1 { break }
        pid = info.ppid
    }
    s.agentPid = agent
    // Hooks run detached from the terminal, so ask the agent process which tty it sits on.
    s.tty = controllingTTY(of: agent) ?? controllingTTY(of: getpid())
}

struct ProcInfo { var ppid: pid_t; var name: String }

func processInfo(_ pid: pid_t) -> ProcInfo? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let name = withUnsafePointer(to: &info.kp_proc.p_comm) { ptr -> String in
        ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
    }
    return ProcInfo(ppid: info.kp_eproc.e_ppid, name: name)
}

/// "ttys003" for the controlling terminal, or nil when there is none.
func controllingTTY(of pid: pid_t) -> String? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let dev = info.kp_eproc.e_tdev
    guard dev != 0, dev != -1, let name = devname(dev, S_IFCHR) else { return nil }
    return String(cString: name)
}

main()
