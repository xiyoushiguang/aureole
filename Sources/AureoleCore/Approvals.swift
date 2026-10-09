import Foundation

/// Approving a permission request from the panel instead of the terminal. Off unless the user turns it on.
///
/// The PermissionRequest hook writes a request file and waits (briefly) for the app to write a decision next
/// to it. A decision prints `{"hookSpecificOutput": {"decision": {"behavior": "allow"|"deny"}}}`; no decision
/// in time prints nothing, so the agent shows its own prompt as if Aureole were not there. Only "allow once"
/// and "deny" exist: no standing rules, nothing approved without a click on a card that shows the full request.
public struct ApprovalRequest: Codable, Equatable, Identifiable, Sendable {
    /// Unique per request, so a late or stale decision never applies to a different one.
    public var id: String
    public var sessionId: String
    public var provider: ProviderID
    public var tool: String
    /// Everything the tool would do, untruncated: the full command, or the file and the change.
    public var full: String
    public var at: Date
    /// After this the hook has given up and the terminal prompt is showing.
    public var expires: Date
    /// Set when Claude is asking a question (AskUserQuestion) instead of asking for permission.
    public var questions: [Question]?

    public struct Question: Codable, Equatable, Sendable {
        public var question: String
        public var header: String?
        public var options: [Option]
        public var multiSelect: Bool
        public struct Option: Codable, Equatable, Sendable {
            public var label: String
            public var description: String?
        }
    }

    public init(id: String, sessionId: String, provider: ProviderID, tool: String, full: String, at: Date, expires: Date,
                questions: [Question]? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.provider = provider
        self.tool = tool
        self.full = full
        self.at = at
        self.expires = expires
        self.questions = questions
    }

    /// The questions in an AskUserQuestion tool input; nil when there are none with options to pick.
    public static func questions(from input: [String: Any]?) -> [Question]? {
        let list = (input?["questions"] as? [[String: Any]] ?? []).compactMap { q -> Question? in
            guard let text = q["question"] as? String else { return nil }
            let options = (q["options"] as? [[String: Any]] ?? []).compactMap { o -> Question.Option? in
                (o["label"] as? String).map { Question.Option(label: $0, description: o["description"] as? String) }
            }
            guard !options.isEmpty else { return nil }
            return Question(question: text, header: q["header"] as? String, options: options,
                            multiSelect: q["multiSelect"] as? Bool ?? false)
        }
        return list.isEmpty ? nil : list
    }

    /// The full, human-readable request for a tool call. Never shortened: this is what the user approves.
    public static func fullText(tool: String, input: [String: Any]?) -> String {
        let i = input ?? [:]
        if let cmd = i["command"] as? String { return cmd }
        if let argv = i["command"] as? [String] { return argv.joined(separator: " ") }
        var lines: [String] = []
        for key in ["file_path", "notebook_path", "path", "url", "pattern", "query"] {
            if let v = i[key] as? String { lines.append(v) }
        }
        let rest = i.filter { !["file_path", "notebook_path", "path", "url", "pattern", "query"].contains($0.key) }
        if !rest.isEmpty, let data = try? JSONSerialization.data(withJSONObject: rest, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            lines.append(json)
        }
        return lines.isEmpty ? tool : lines.joined(separator: "\n")
    }
}

public enum ApprovalDecision: String, Codable, Sendable {
    case allow, deny

    /// What the hook prints so the agent takes the decision (same shape for Claude Code and Codex).
    public var hookOutput: String {
        var decision: [String: Any] = ["behavior": rawValue]
        if self == .deny { decision["message"] = "Denied from Aureole" }
        let obj: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// What the panel sent back: a permission decision, or answers to Claude's questions (question text → chosen
/// label; several labels joined with ", " for a multi-select question).
public enum ApprovalReply: Equatable, Sendable {
    case decision(ApprovalDecision)
    case answers([String: String])

    /// What the PreToolUse hook prints to answer AskUserQuestion: allow, with the original input plus `answers`.
    public static func answersOutput(_ answers: [String: String], input: [String: Any]) -> String {
        var updated = input
        updated["answers"] = answers
        let obj: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "allow",
                                                         "updatedInput": updated]]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

public enum ApprovalFiles {
    /// UserDefaults key (in the app's domain, read by the hook too): seconds the hook waits; 0 = off.
    public static let waitKey = "approveFromPanelSeconds"

    public static var directory: URL {
        let dir = AureolePaths.appSupport.appendingPathComponent("approvals", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    static func safe(_ id: String) -> String { id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }
    static func requestURL(_ id: String, in dir: URL) -> URL { dir.appendingPathComponent("\(safe(id)).json") }
    static func decisionURL(_ id: String, in dir: URL) -> URL { dir.appendingPathComponent("\(safe(id)).decision") }

    public static func save(_ r: ApprovalRequest, in dir: URL = directory) throws {
        let url = requestURL(r.id, in: dir)
        try JSONEncoder.aureole.encode(r).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Requests still open; expired ones (and their files) are dropped.
    public static func pending(in dir: URL = directory, now: Date = Date()) -> [ApprovalRequest] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let r = try? JSONDecoder.aureole.decode(ApprovalRequest.self, from: data) else { return nil }
            if r.expires < now.addingTimeInterval(-5) { remove(r.id, in: dir); return nil }
            return r.expires > now ? r : nil
        }
    }

    /// The app records the user's click. Only for a request that is still open.
    public static func decide(_ id: String, _ d: ApprovalDecision, in dir: URL = directory, now: Date = Date()) -> Bool {
        guard pending(in: dir, now: now).contains(where: { $0.id == id }) else { return false }
        let url = decisionURL(id, in: dir)
        guard (try? Data(d.rawValue.utf8).write(to: url, options: .atomic)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }

    /// The app records answers to a question request. Only for a request that is still open.
    public static func answer(_ id: String, _ answers: [String: String], in dir: URL = directory, now: Date = Date()) -> Bool {
        guard pending(in: dir, now: now).contains(where: { $0.id == id }),
              let data = try? JSONSerialization.data(withJSONObject: ["answers": answers]) else { return false }
        let url = decisionURL(id, in: dir)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }

    /// The hook polls for a decision until the deadline; nil means "let the agent ask as usual".
    public static func wait(for id: String, until deadline: Date, in dir: URL = directory,
                            poll: TimeInterval = 0.2) -> ApprovalDecision? {
        if case .decision(let d)? = waitReply(for: id, until: deadline, in: dir, poll: poll) { return d }
        return nil
    }

    public static func waitReply(for id: String, until deadline: Date, in dir: URL = directory,
                                 poll: TimeInterval = 0.2) -> ApprovalReply? {
        let url = decisionURL(id, in: dir)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url) {
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if let d = ApprovalDecision(rawValue: text) { return .decision(d) }
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let answers = obj["answers"] as? [String: String] { return .answers(answers) }
            }
            Thread.sleep(forTimeInterval: poll)
        }
        return nil
    }

    public static func remove(_ id: String, in dir: URL = directory) {
        try? FileManager.default.removeItem(at: requestURL(id, in: dir))
        try? FileManager.default.removeItem(at: decisionURL(id, in: dir))
    }
}
