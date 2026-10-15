import Foundation

/// Lanes for anything that is not an agent: a nightly job, a long build, a batch of renders. A script reports
/// its state with the hook helper and gets a lane on the same time axis as the sessions:
///
///     aureole-hook --lane nightly --name "Nightly run" --state working --detail "step 2 of 5" --progress 0.4
///     aureole-hook --lane nightly --state done
///     aureole-hook --lane nightly --state end      # removes the lane
///
/// States: working, waiting (needs you), done, idle, end. The lane goes away when the reporting process
/// (by default the script that called the helper) exits, or after hours of silence like any session.
public struct TaskLaneUpdate: Equatable, Sendable {
    public enum State: String, Sendable { case working, waiting, done, idle, end }
    public var id: String
    public var state: State?
    public var name: String?
    public var detail: String?
    public var progress: Double?
    /// A path or URL a click on the lane opens.
    public var open: String?
    /// The process whose life the lane follows; nil to keep the one recorded.
    public var pid: Int32?

    public static let flag = "--lane"

    public init(id: String, state: State? = nil, name: String? = nil, detail: String? = nil, progress: Double? = nil,
                open: String? = nil, pid: Int32? = nil) {
        self.id = id
        self.state = state
        self.name = name
        self.detail = detail
        self.progress = progress
        self.open = open
        self.pid = pid
    }

    /// Parses `--lane <id> [--state s] [--name n] [--detail d] [--progress 0…1 or 0…100%] [--open target] [--pid n]`.
    public static func parse(_ args: [String]) -> Result<TaskLaneUpdate, LaneError> {
        var values: [String: String] = [:]
        var i = 0
        while i < args.count {
            let key = args[i]
            guard key.hasPrefix("--"), i + 1 < args.count else { return .failure(.usage("expected --option value, got \(key)")) }
            values[String(key.dropFirst(2))] = args[i + 1]
            i += 2
        }
        guard let rawId = values["lane"], !rawId.isEmpty else { return .failure(.usage("--lane needs an id")) }
        let id = rawId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        guard !id.isEmpty else { return .failure(.usage("the lane id may use letters, digits, - _ .")) }
        var u = TaskLaneUpdate(id: id)
        if let s = values["state"] {
            guard let st = State(rawValue: s.lowercased()) else { return .failure(.usage("unknown state \(s)")) }
            u.state = st
        }
        u.name = values["name"]
        u.detail = values["detail"]
        u.open = values["open"]
        if let p = values["progress"] {
            let pct = p.hasSuffix("%")
            guard let v = Double(pct ? String(p.dropLast()) : p) else { return .failure(.usage("--progress takes 0…1 or a percentage")) }
            u.progress = min(1, max(0, pct || v > 1 ? v / 100 : v))
        }
        if let p = values["pid"] { u.pid = Int32(p) }
        let unknown = Set(values.keys).subtracting(["lane", "state", "name", "detail", "progress", "open", "pid"])
        if let k = unknown.first { return .failure(.usage("unknown option --\(k)")) }
        return .success(u)
    }

    public enum LaneError: Error, Equatable { case usage(String) }

    /// A script usually reports `done` and exits at once. Its lane outlives it for this long, so the check mark
    /// shows and the finish is announced; other lanes leave with their process.
    public static let doneLinger: TimeInterval = 30 * 60

    public static func keepsAfterExit(_ s: AgentSession, now: Date) -> Bool {
        s.provider == .task && s.state == .idle && s.lastEvent == "Stop" && now.timeIntervalSince(s.stateSince) < doneLinger
    }

    /// The session id lanes are stored under, apart from agents' ids.
    public var sessionId: String { "task-" + id }

    /// Folds the update into the lane's record; nil when the lane should be removed.
    public func apply(to existing: AgentSession?, now: Date) -> AgentSession? {
        if state == .end { return nil }
        var s = existing ?? AgentSession(provider: .task, sessionId: sessionId, cwd: "", now: now)
        s.updatedAt = now
        s.background = false
        if let name { s.firstPrompt = name }
        if s.firstPrompt == nil { s.firstPrompt = id }
        if let detail { s.lastTool = detail; s.lastDetail = nil }
        if let progress { s.progress = progress }
        if let open { s.openTarget = open }
        if let pid { s.agentPid = pid }
        switch state {
        case .working?:
            if s.state != .working { s.turnStartedAt = now; s.turns += 1; s.waitingMessage = nil }
            s.set(.working, at: now)
            s.lastEvent = "TaskWorking"
        case .waiting?:
            s.set(.waitingInput, at: now)
            s.waitingMessage = detail ?? s.lastTool
            s.lastEvent = "TaskWaiting"
        case .done?:
            // Counts as a finished task (announced once, shown with a check) like an agent's long turn.
            if s.turnStartedAt == nil { s.turnStartedAt = s.startedAt }
            s.set(.idle, at: now)
            s.lastEvent = "Stop"
            s.waitingMessage = nil
        case .idle?:
            s.set(.idle, at: now)
            s.lastEvent = "TaskIdle"
            s.waitingMessage = nil
        case .end?, nil:
            break
        }
        return s
    }
}
