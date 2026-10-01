import Foundation

/// What an agent session is doing right now, as far as its hooks have told us.
public enum SessionState: String, Codable, Sendable {
    case working            // inside a turn: thinking or running tools
    case waitingPermission  // a permission prompt is on screen
    case waitingInput       // the agent asked a question or opened a dialog
    case idle               // turn finished, waiting for the next prompt
    case ended

    public var needsYou: Bool { self == .waitingPermission || self == .waitingInput }
}

/// One Claude Code (later: Codex) session, persisted as `sessions/<id>.json` by the hook helper.
public struct AgentSession: Codable, Equatable, Identifiable, Sendable {
    public var v: Int = 1
    public var provider: ProviderID
    public var sessionId: String
    public var cwd: String
    public var transcriptPath: String?
    /// The agent process (first ancestor of the hook that looks like the CLI), used to tell live sessions from dead files.
    public var agentPid: Int32?
    public var tty: String?
    public var termProgram: String?
    public var termSessionId: String?
    public var bundleId: String?
    public var tmuxPane: String?
    public var startedAt: Date
    public var updatedAt: Date
    public var state: SessionState
    public var stateSince: Date
    public var lastEvent: String?
    public var lastTool: String?
    public var lastDetail: String?
    public var waitingMessage: String?
    public var promptPreview: String?
    public var turns: Int = 0
    /// The last few tool calls, newest first. Optional so files written by older helpers still decode.
    public var recent: [SessionActivity]?

    public var id: String { sessionId }
    public var projectName: String { (cwd as NSString).lastPathComponent }

    public init(provider: ProviderID, sessionId: String, cwd: String, now: Date) {
        self.provider = provider
        self.sessionId = sessionId
        self.cwd = cwd
        startedAt = now
        updatedAt = now
        state = .idle
        stateSince = now
    }

    public mutating func set(_ new: SessionState, at now: Date) {
        if state != new { stateSince = now }
        state = new
    }
}

public struct SessionActivity: Codable, Equatable, Sendable {
    public var at: Date
    public var text: String
    public init(at: Date, text: String) { self.at = at; self.text = text }
}

/// A hook invocation, decoded from the JSON Claude Code writes to the hook's stdin.
public struct HookEvent {
    public var name: String
    public var sessionId: String
    public var cwd: String
    public var transcriptPath: String?
    public var toolName: String?
    public var toolInput: [String: Any]?
    public var message: String?
    public var notificationType: String?
    public var prompt: String?
    public var reason: String?

    public init?(json: [String: Any]) {
        guard let name = json["hook_event_name"] as? String, let id = json["session_id"] as? String, !id.isEmpty else { return nil }
        self.name = name
        sessionId = id
        cwd = json["cwd"] as? String ?? ""
        transcriptPath = json["transcript_path"] as? String
        toolName = json["tool_name"] as? String
        toolInput = json["tool_input"] as? [String: Any]
        message = json["message"] as? String
        notificationType = json["notification_type"] as? String
        prompt = json["prompt"] as? String
        reason = json["reason"] as? String
    }
}

/// Pure state machine: folds one hook event into a session record.
public enum SessionReducer {
    public static func apply(_ e: HookEvent, to existing: AgentSession?, now: Date, keepPrompt: Bool = true) -> AgentSession {
        var s = existing ?? AgentSession(provider: .claude, sessionId: e.sessionId, cwd: e.cwd, now: now)
        if !e.cwd.isEmpty { s.cwd = e.cwd }
        if let t = e.transcriptPath { s.transcriptPath = t }
        s.updatedAt = now
        s.lastEvent = e.name
        switch e.name {
        case "SessionStart":
            s.set(.idle, at: now)
            s.waitingMessage = nil
        case "UserPromptSubmit":
            s.set(.working, at: now)
            s.turns += 1
            s.waitingMessage = nil
            s.lastTool = nil
            s.lastDetail = nil
            if keepPrompt, let p = e.prompt { s.promptPreview = Self.oneLine(p, max: 80) }
        case "PreToolUse":
            s.lastTool = e.toolName
            s.lastDetail = Self.detail(tool: e.toolName, input: e.toolInput)
            if let tool = e.toolName {
                let text = [tool, s.lastDetail].compactMap { $0 }.joined(separator: " · ")
                s.recent = Array(([SessionActivity(at: now, text: text)] + (s.recent ?? [])).prefix(3))
            }
            if e.toolName == "AskUserQuestion" {
                s.set(.waitingInput, at: now)
                s.waitingMessage = s.lastDetail
            } else {
                s.set(.working, at: now)
                s.waitingMessage = nil
            }
        case "PostToolUse", "PostToolUseFailure", "PreCompact", "SubagentStop":
            s.set(.working, at: now)
            s.waitingMessage = nil
        case "PermissionRequest":
            s.set(.waitingPermission, at: now)
            s.lastTool = e.toolName ?? s.lastTool
            let d = Self.detail(tool: e.toolName, input: e.toolInput)
            s.lastDetail = d ?? s.lastDetail
            s.waitingMessage = [e.toolName, d].compactMap { $0 }.joined(separator: ": ")
        case "Notification":
            switch e.notificationType ?? "" {
            case "permission_prompt":
                s.set(.waitingPermission, at: now)
                s.waitingMessage = e.message ?? s.waitingMessage
            case "elicitation_dialog":
                s.set(.waitingInput, at: now)
                s.waitingMessage = e.message ?? s.waitingMessage
            case "idle_prompt":
                s.set(.idle, at: now)
            default:
                break
            }
        case "Stop":
            s.set(.idle, at: now)
            s.waitingMessage = nil
        case "SessionEnd":
            s.set(.ended, at: now)
            s.waitingMessage = nil
        default:
            break
        }
        return s
    }

    /// A short, human description of what a tool call is about; never the full input.
    public static func detail(tool: String?, input: [String: Any]?) -> String? {
        guard let tool else { return nil }
        let i = input ?? [:]
        func str(_ k: String) -> String? { (i[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func base(_ k: String) -> String? { str(k).map { ($0 as NSString).lastPathComponent } }
        switch tool {
        case "Bash": return str("description").map { oneLine($0, max: 60) } ?? str("command").map { oneLine($0, max: 60) }
        case "Edit", "Write", "Read", "MultiEdit", "NotebookEdit": return base("file_path") ?? base("notebook_path")
        case "Grep", "Glob": return str("pattern")
        case "Agent", "Task": return str("description")
        case "WebFetch": return str("url")
        case "WebSearch": return str("query")
        case "Skill": return str("skill")
        case "AskUserQuestion":
            let q = (i["questions"] as? [[String: Any]])?.first?["question"] as? String
            return q.map { oneLine($0, max: 80) }
        default: return nil
        }
    }

    static func oneLine(_ s: String, max: Int) -> String {
        let flat = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = flat.trimmingCharacters(in: .whitespaces)
        return trimmed.count > max ? String(trimmed.prefix(max - 1)) + "…" : trimmed
    }
}

/// Sorting and grouping for the panel. `alive` tells whether the agent process still exists.
public struct SessionBoard: Equatable, Sendable {
    public var waiting: [AgentSession] = []
    public var working: [AgentSession] = []
    public var idle: [AgentSession] = []

    public init() {}

    public var isEmpty: Bool { waiting.isEmpty && working.isEmpty && idle.isEmpty }
    public var all: [AgentSession] { waiting + working + idle }

    /// Sessions that have not reported anything for this long are treated as gone even if a process is still alive.
    public static let staleAfter: TimeInterval = 6 * 3600

    public static func build(_ sessions: [AgentSession], now: Date, alive: (AgentSession) -> Bool) -> SessionBoard {
        var b = SessionBoard()
        for s in sessions {
            guard s.state != .ended, now.timeIntervalSince(s.updatedAt) < staleAfter, alive(s) else { continue }
            switch s.state {
            case .waitingPermission, .waitingInput: b.waiting.append(s)
            case .working: b.working.append(s)
            case .idle: b.idle.append(s)
            case .ended: break
            }
        }
        b.waiting.sort { $0.stateSince < $1.stateSince }      // longest wait first
        b.working.sort { $0.updatedAt > $1.updatedAt }
        b.idle.sort { $0.updatedAt > $1.updatedAt }
        return b
    }
}

/// Reads and writes the per-session files the hook helper maintains.
public enum SessionFiles {
    public static var directory: URL {
        let dir = AureolePaths.appSupport.appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    public static func url(for sessionId: String, in dir: URL = directory) -> URL {
        let safe = sessionId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return dir.appendingPathComponent("\(safe).json")
    }

    public static func load(_ url: URL) -> AgentSession? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.aureole.decode(AgentSession.self, from: data)
    }

    public static func save(_ s: AgentSession, in dir: URL = directory) throws {
        let data = try JSONEncoder.aureole.encode(s)
        let url = url(for: s.sessionId, in: dir)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func loadAll(in dir: URL = directory) -> [AgentSession] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap(load)
    }
}

/// Installs the hook helper into ~/.claude/settings.json without disturbing anything else in it.
public enum HookInstaller {
    public static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
                                "Notification", "Stop", "SessionEnd"]
    public static let marker = "aureole-hook"

    public static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    public enum Status: Equatable, Sendable { case installed(events: Int), partial(events: Int), notInstalled }

    public static func status(settings: [String: Any]) -> Status {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        let n = events.filter { contains(hooks[$0]) }.count
        if n == 0 { return .notInstalled }
        return n == events.count ? .installed(events: n) : .partial(events: n)
    }

    static func contains(_ entries: Any?) -> Bool {
        guard let list = entries as? [[String: Any]] else { return false }
        return list.contains { entry in
            ((entry["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String)?.contains(marker) == true }
        }
    }

    /// Returns the settings with our hook added to every event (idempotent) or removed from all of them.
    public static func merge(settings: [String: Any], helperPath: String, install: Bool) -> [String: Any] {
        var out = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var list = (hooks[event] as? [[String: Any]]) ?? []
            // Drop any earlier Aureole entry, then re-add so a moved helper path is picked up.
            list = list.compactMap { entry in
                var e = entry
                let kept = ((entry["hooks"] as? [[String: Any]]) ?? []).filter { ($0["command"] as? String)?.contains(marker) != true }
                if kept.isEmpty && (entry["hooks"] as? [[String: Any]])?.isEmpty == false { return nil }
                e["hooks"] = kept
                return e
            }
            if install {
                list.append(["hooks": [["type": "command", "command": quoted(helperPath), "timeout": 5]]])
            }
            if list.isEmpty { hooks[event] = nil } else { hooks[event] = list }
        }
        if hooks.isEmpty { out["hooks"] = nil } else { out["hooks"] = hooks }
        return out
    }

    static func quoted(_ path: String) -> String {
        path.contains(" ") ? "\"\(path)\"" : path
    }

    public static func read(url: URL = settingsURL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Aureole", code: 1, userInfo: [NSLocalizedDescriptionKey: "settings.json is not a JSON object"])
        }
        return obj
    }

    /// Writes with a one-time backup beside the file. Keys are sorted so diffs stay readable.
    public static func write(_ settings: [String: Any], url: URL = settingsURL) throws {
        let fm = FileManager.default
        let backup = url.appendingPathExtension("bak-aureole")
        if fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) {
            try? fm.copyItem(at: url, to: backup)
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}

/// Reads a session's title and context size from the tail of its Claude Code transcript.
public enum TranscriptReader {
    public struct Summary: Equatable, Sendable {
        /// Tokens the model saw on its latest main-thread turn (input + cache writes + cache reads).
        public var contextTokens: Int?
        /// The short title Claude Code generates for the conversation.
        public var title: String?
        public init(contextTokens: Int? = nil, title: String? = nil) { self.contextTokens = contextTokens; self.title = title }
    }

    public static func summary(inTail text: Substring) -> Summary {
        var out = Summary()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            if out.contextTokens != nil, out.title != nil { break }
            if out.title == nil, line.contains("\"ai-title\""),
               let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               obj["type"] as? String == "ai-title", let t = obj["aiTitle"] as? String, !t.isEmpty {
                out.title = t
                continue
            }
            if out.contextTokens == nil, line.contains("\"usage\""), line.contains("\"assistant\""),
               let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               obj["type"] as? String == "assistant", (obj["isSidechain"] as? Bool) != true,
               let usage = (obj["message"] as? [String: Any])?["usage"] as? [String: Any] {
                func n(_ k: String) -> Int { (usage[k] as? NSNumber)?.intValue ?? 0 }
                let total = n("input_tokens") + n("cache_creation_input_tokens") + n("cache_read_input_tokens")
                if total > 0 { out.contextTokens = total }
            }
        }
        return out
    }

    public static func contextTokens(inTail text: Substring) -> Int? { summary(inTail: text).contextTokens }

    /// Looks only at the last few megabytes; transcripts grow to tens of MB.
    public static func summary(path: String, tailBytes: UInt64 = 3 << 20) -> Summary {
        guard let h = FileHandle(forReadingAtPath: path) else { return Summary() }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > tailBytes ? size - tailBytes : 0)
        guard let data = try? h.readToEnd() else { return Summary() }
        // The cut can land inside a multi-byte character, so decode leniently.
        let text = String(decoding: data, as: UTF8.self)
        return summary(inTail: Substring(text))
    }

    /// 489_136 → "489k", 1_240_000 → "1.2M".
    public static func short(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return "\(tokens / 1_000)k" }
        return "\(tokens)"
    }
}
