import Foundation

public enum UsageEvent: Equatable, Sendable {
    case threshold(provider: ProviderID, window: UsageWindow, level: Int)
    case reset(provider: ProviderID, window: UsageWindow)
    case forecast(provider: ProviderID, window: UsageWindow, exhaustAt: Date)
    case authLost(provider: ProviderID, message: String)
    /// A session has been waiting on you since `since`: for an approval, or (`question`) for an answer.
    case sessionWaiting(provider: ProviderID, name: String, detail: String?, since: Date, question: Bool)
    /// A session finished a task that took `took`.
    case sessionDone(provider: ProviderID, name: String, took: TimeInterval)

    public var provider: ProviderID {
        switch self {
        case .threshold(let p, _, _), .reset(let p, _), .forecast(let p, _, _), .authLost(let p, _),
             .sessionWaiting(let p, _, _, _, _), .sessionDone(let p, _, _): return p
        }
    }

    public var kind: String {
        switch self {
        case .threshold: return "threshold"
        case .reset: return "reset"
        case .forecast: return "forecast"
        case .authLost: return "auth_lost"
        case .sessionWaiting: return "session_waiting"
        case .sessionDone: return "session_done"
        }
    }

    public var title: String {
        switch self {
        case .threshold(let p, let w, let level): return L10n.f("%@ %@ window at %d%%", p.displayName, w.displayLabel, level)
        case .reset(let p, let w): return L10n.f("%@ %@ window reset", p.displayName, w.displayLabel)
        case .forecast(let p, let w, _): return L10n.f("%@ %@ will run out before reset", p.displayName, w.displayLabel)
        case .authLost(let p, _): return L10n.f("%@ sign-in needed", p.displayName)
        // The marks echo the panel: amber for waiting on you, a green tick for done.
        case .sessionWaiting(_, let name, _, _, let question):
            return "🟠 " + L10n.f(question ? "%@ has a question for you" : "%@ needs your approval", name)
        case .sessionDone(_, let name, _): return "✅ " + L10n.f("%@ is done", name)
        }
    }

    public var body: String {
        switch self {
        case .threshold(_, let w, _):
            return L10n.f("Used %d%%", Int(w.usedPercent.rounded())) + (w.resetsAt.map { L10n.f(", resets %@", Formatting.resetText($0)) } ?? "")
        case .reset(_, let w):
            return L10n.t("Fresh window") + (w.resetsAt.map { L10n.f(", next reset %@", Formatting.resetText($0)) } ?? "")
        case .forecast(_, let w, let at):
            return L10n.f("At the current pace it hits 100%% around %@", HorizonHeadline.when(at, now: Date())) + (w.resetsAt.map { L10n.f(", reset is %@", Formatting.resetText($0)) } ?? "")
        case .authLost(_, let m):
            return m
        case .sessionWaiting(_, _, let detail, let since, _):
            let waited = L10n.f("waited %@", Formatting.countdown(Date().timeIntervalSince(since)))
            return detail.map { "\($0) · \(waited)" } ?? waited
        case .sessionDone(_, _, let took):
            return L10n.f("Finished after %@", Formatting.countdown(took))
        }
    }

    public var percent: Double? {
        switch self {
        case .threshold(_, let w, _), .reset(_, let w), .forecast(_, let w, _): return w.usedPercent
        case .authLost, .sessionWaiting, .sessionDone: return nil
        }
    }
}

/// Turns consecutive snapshots into de-duplicated events.
public struct EventDetector: Sendable {
    public var thresholds: [Int]
    public var forecastMinimumPercent: Double
    /// Weekly windows warn earlier: there is more room to change course.
    public var weeklyForecastMinimumPercent: Double = 20
    /// Events already delivered: "provider|window|kind" → the reset time (epoch) of the cycle they were sent for.
    /// Persist this so a relaunch never re-sends. Reset times drift by a few seconds between fetches, so
    /// matching uses a tolerance rather than exact equality.
    public var sent: [String: Double]

    public init(thresholds: [Int] = [80, 95], forecastMinimumPercent: Double = 40, sent: [String: Double] = [:]) {
        self.thresholds = thresholds.sorted()
        self.forecastMinimumPercent = forecastMinimumPercent
        self.sent = sent
    }

    /// `weekly` holds average-pace forecasts for the long windows, by window key.
    public mutating func detect(previous: ProviderSnapshot?, current: ProviderSnapshot,
                                prediction: Prediction?, weekly: [String: Prediction] = [:], now: Date = Date()) -> [UsageEvent] {
        var events: [UsageEvent] = []
        for w in current.windows where w.kind != .other {
            let prev = previous?.windows.first { $0.key == w.key }
            let base = "\(current.provider.rawValue)|\(w.key)"
            if let prev, prev.resetsAt != nil, w.resetsAt != nil,
               !Predictor.sameCycle(prev.resetsAt, w.resetsAt), prev.usedPercent >= 25,
               mark("\(base)|reset", cycle: w.resetsAt) {
                events.append(.reset(provider: current.provider, window: w))
            }
            for level in thresholds where w.usedPercent >= Double(level) {
                let crossed = prev.map { $0.usedPercent < Double(level) || !Predictor.sameCycle($0.resetsAt, w.resetsAt) } ?? true
                if crossed, mark("\(base)|t\(level)", cycle: w.resetsAt) {
                    events.append(.threshold(provider: current.provider, window: w, level: level))
                }
            }
            if w.kind == .fiveHour, let p = prediction, p.exhaustsBeforeReset, let at = p.exhaustAt,
               w.usedPercent >= forecastMinimumPercent, mark("\(base)|forecast", cycle: w.resetsAt) {
                events.append(.forecast(provider: current.provider, window: w, exhaustAt: at))
            }
            if w.kind == .sevenDay, let p = weekly[w.key], p.exhaustsBeforeReset, let at = p.exhaustAt,
               w.usedPercent >= weeklyForecastMinimumPercent, mark("\(base)|forecast", cycle: w.resetsAt) {
                events.append(.forecast(provider: current.provider, window: w, exhaustAt: at))
            }
        }
        // Keep the de-dupe set from growing forever.
        if sent.count > 500 { sent.removeAll() }
        return events
    }

    public mutating func authLost(_ provider: ProviderID, message: String, now: Date = Date()) -> UsageEvent? {
        // Re-arms after five minutes so a sign-in that keeps failing is mentioned again, but not every minute.
        mark("\(provider.rawValue)|auth", cycle: now) ? .authLost(provider: provider, message: message) : nil
    }

    /// True the first time an event is seen for this cycle (reset time within five minutes of a recorded one).
    private mutating func mark(_ key: String, cycle: Date?) -> Bool {
        let epoch = cycle?.timeIntervalSince1970 ?? 0
        if let old = sent[key], abs(old - epoch) < 300 { return false }
        sent[key] = epoch
        return true
    }
}

public enum ChannelKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case native, discord, slack, telegram, feishu, dingtalk, wecom, ntfy, bark, serverchan, webhook, shell

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .native: return L10n.t("macOS Notification")
        case .discord: return "Discord"
        case .slack: return "Slack"
        case .telegram: return "Telegram"
        case .feishu: return L10n.t("Feishu / Lark")
        case .dingtalk: return L10n.t("DingTalk")
        case .wecom: return L10n.t("WeCom")
        case .ntfy: return "ntfy"
        case .bark: return "Bark"
        case .serverchan: return L10n.t("ServerChan (WeChat)")
        case .webhook: return L10n.t("Custom webhook")
        case .shell: return L10n.t("Shell script")
        }
    }

    /// Which fields the settings UI should ask for.
    public var fields: [ChannelField] {
        switch self {
        case .native: return []
        case .discord, .slack, .feishu, .dingtalk, .wecom: return [.url]
        case .telegram: return [.token, .target]
        case .ntfy: return [.url]
        case .bark: return [.url, .token]
        case .serverchan: return [.token]
        case .webhook: return [.url, .headers, .body]
        case .shell: return [.target]
        }
    }

    public var hint: String {
        switch self {
        case .native: return L10n.t("Uses Notification Center. Allow notifications when macOS asks.")
        case .discord: return L10n.t("Channel settings → Integrations → Webhooks → copy URL.")
        case .slack: return L10n.t("Incoming Webhook URL from api.slack.com/apps.")
        case .telegram: return L10n.t("Bot token from @BotFather and your chat id (message @userinfobot).")
        case .feishu: return L10n.t("Group → Settings → Bots → Custom bot → webhook URL.")
        case .dingtalk: return L10n.t("Group robot webhook URL (security setting: custom keyword ‘Aureole’).")
        case .wecom: return L10n.t("Group robot webhook URL.")
        case .ntfy: return L10n.t("Topic URL, e.g. https://ntfy.sh/my-aureole.")
        case .bark: return L10n.t("Server URL (default https://api.day.app) and your device key.")
        case .serverchan: return L10n.t("SendKey from sct.ftqq.com; delivers to WeChat.")
        case .webhook: return L10n.t("POST with a JSON template. Placeholders: {{title}} {{body}} {{event}} {{provider}} {{percent}}.")
        case .shell: return L10n.t("Path to an executable. Receives AUREOLE_* env vars and a JSON event on stdin.")
        }
    }
}

public enum ChannelField: String, Codable, Sendable { case url, token, target, headers, body }

public struct ChannelConfig: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: ChannelKind
    public var name: String
    public var enabled: Bool
    public var url: String
    public var token: String
    public var target: String
    public var headers: [String: String]
    public var bodyTemplate: String

    public init(id: UUID = UUID(), kind: ChannelKind, name: String? = nil, enabled: Bool = true,
                url: String = "", token: String = "", target: String = "",
                headers: [String: String] = [:], bodyTemplate: String = "") {
        self.id = id
        self.kind = kind
        self.name = name ?? kind.displayName
        self.enabled = enabled
        self.url = url
        self.token = token
        self.target = target
        self.headers = headers
        self.bodyTemplate = bodyTemplate
    }

    public static let defaultWebhookTemplate = """
    {"title": "{{title}}", "body": "{{body}}", "event": "{{event}}", "provider": "{{provider}}", "percent": "{{percent}}"}
    """
}

public enum ChannelDispatchError: Error, LocalizedError {
    case badConfig(String), http(Int, String), transport(String), shell(Int32, String)
    public var errorDescription: String? {
        switch self {
        case .badConfig(let m): return m
        case .http(let c, let m): return "HTTP \(c) \(m)"
        case .transport(let m): return m
        case .shell(let code, let m): return "script exited \(code): \(m)"
        }
    }
}

/// Builds and sends the HTTP request (or runs the script) for one channel.
public enum ChannelDispatcher {
    public static func send(_ event: UsageEvent, to config: ChannelConfig) async throws {
        switch config.kind {
        case .native:
            return // handled by the app layer
        case .shell:
            try runShell(event, config)
        default:
            let req = try request(for: event, config: config)
            let (data, http) = try await HTTPClient.perform(req)
            guard (200..<300).contains(http.statusCode) else {
                throw ChannelDispatchError.http(http.statusCode, String(data: data.prefix(160), encoding: .utf8) ?? "")
            }
        }
    }

    public static func request(for event: UsageEvent, config: ChannelConfig) throws -> URLRequest {
        let text = "\(event.title)\n\(event.body)"
        func json(_ url: String, _ obj: Any) throws -> URLRequest {
            guard let u = URL(string: url), u.scheme?.hasPrefix("http") == true else {
                throw ChannelDispatchError.badConfig("\(config.name): invalid URL")
            }
            var r = URLRequest(url: u)
            r.httpMethod = "POST"
            r.timeoutInterval = 15
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue(AureoleInfo.userAgent, forHTTPHeaderField: "User-Agent")
            r.httpBody = try JSONSerialization.data(withJSONObject: obj)
            return r
        }
        switch config.kind {
        case .discord:
            return try json(config.url, ["content": "**\(event.title)**\n\(event.body)"])
        case .slack:
            return try json(config.url, ["text": "*\(event.title)*\n\(event.body)"])
        case .feishu:
            return try json(config.url, ["msg_type": "text", "content": ["text": text]])
        case .dingtalk, .wecom:
            return try json(config.url, ["msgtype": "text", "text": ["content": "Aureole · \(text)"]])
        case .telegram:
            guard !config.token.isEmpty, !config.target.isEmpty else {
                throw ChannelDispatchError.badConfig("Telegram needs a bot token and chat id")
            }
            return try json("https://api.telegram.org/bot\(config.token)/sendMessage",
                            ["chat_id": config.target, "text": text])
        case .ntfy:
            guard let u = URL(string: config.url) else { throw ChannelDispatchError.badConfig("ntfy needs a topic URL") }
            var r = URLRequest(url: u)
            r.httpMethod = "POST"
            r.setValue(event.title, forHTTPHeaderField: "Title")
            r.setValue("aureole", forHTTPHeaderField: "Tags")
            r.httpBody = event.body.data(using: .utf8)
            return r
        case .bark:
            let base = config.url.isEmpty ? "https://api.day.app" : config.url
            guard !config.token.isEmpty else { throw ChannelDispatchError.badConfig("Bark needs a device key") }
            return try json("\(base.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(config.token)",
                            ["title": event.title, "body": event.body, "group": "Aureole"])
        case .serverchan:
            guard !config.token.isEmpty else { throw ChannelDispatchError.badConfig("ServerChan needs a SendKey") }
            var r = URLRequest(url: URL(string: "https://sctapi.ftqq.com/\(config.token).send")!)
            r.httpMethod = "POST"
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var comps = URLComponents()
            comps.queryItems = [URLQueryItem(name: "title", value: event.title), URLQueryItem(name: "desp", value: event.body)]
            r.httpBody = comps.percentEncodedQuery?.data(using: .utf8)
            return r
        case .webhook:
            guard let u = URL(string: config.url), u.scheme?.hasPrefix("http") == true else {
                throw ChannelDispatchError.badConfig("\(config.name): invalid URL")
            }
            var r = URLRequest(url: u)
            r.httpMethod = "POST"
            r.timeoutInterval = 15
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue(AureoleInfo.userAgent, forHTTPHeaderField: "User-Agent")
            for (k, v) in config.headers { r.setValue(v, forHTTPHeaderField: k) }
            let template = config.bodyTemplate.isEmpty ? ChannelConfig.defaultWebhookTemplate : config.bodyTemplate
            r.httpBody = render(template, event).data(using: .utf8)
            return r
        case .native, .shell:
            throw ChannelDispatchError.badConfig("not an HTTP channel")
        }
    }

    static func render(_ template: String, _ event: UsageEvent) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
        }
        return template
            .replacingOccurrences(of: "{{title}}", with: esc(event.title))
            .replacingOccurrences(of: "{{body}}", with: esc(event.body))
            .replacingOccurrences(of: "{{event}}", with: event.kind)
            .replacingOccurrences(of: "{{provider}}", with: event.provider.rawValue)
            .replacingOccurrences(of: "{{percent}}", with: event.percent.map { String(Int($0.rounded())) } ?? "")
    }

    static func runShell(_ event: UsageEvent, _ config: ChannelConfig) throws {
        guard !config.target.isEmpty, FileManager.default.isExecutableFile(atPath: config.target) else {
            throw ChannelDispatchError.badConfig("\(config.name): script path is not executable")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: config.target)
        var env = ProcessInfo.processInfo.environment
        env["AUREOLE_TITLE"] = event.title
        env["AUREOLE_BODY"] = event.body
        env["AUREOLE_EVENT"] = event.kind
        env["AUREOLE_PROVIDER"] = event.provider.rawValue
        env["AUREOLE_PERCENT"] = event.percent.map { String(Int($0.rounded())) } ?? ""
        p.environment = env
        let input = Pipe(), err = Pipe()
        p.standardInput = input
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        input.fileHandleForWriting.write(render(ChannelConfig.defaultWebhookTemplate, event).data(using: .utf8)!)
        try? input.fileHandleForWriting.close()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ChannelDispatchError.shell(p.terminationStatus, msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

public enum Formatting {
    private static func formatter(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateFormat = pattern
        return f
    }

    public static func clock(_ d: Date) -> String { formatter("HH:mm").string(from: d) }

    /// "2h 13m · 15:35" or "3d 4h · Thu 09:00" (localised units and weekday).
    public static func resetText(_ d: Date, now: Date = Date()) -> String {
        let remaining = d.timeIntervalSince(now)
        if remaining <= 0 { return L10n.t("now") }
        let when = remaining < 20 * 3600 ? clock(d) : formatter("EEE HH:mm").string(from: d)
        return "\(countdown(remaining)) · \(when)"
    }

    public static func countdown(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return L10n.t("<1m") }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return h > 0 ? L10n.f("%dd %dh", d, h) : L10n.f("%dd", d) }
        if h > 0 { return m > 0 ? L10n.f("%dh %dm", h, m) : L10n.f("%dh", h) }
        return L10n.f("%dm", m)
    }

    public static func percent(_ v: Double) -> String { "\(Int(v.rounded()))%" }

    /// "1:20" style countdown for short waits.
    public static func countdownSeconds(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
