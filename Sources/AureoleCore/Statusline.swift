import Foundation

/// What one Claude Code status line update tells us about a session: the subscription's 5-hour and
/// weekly windows (no endpoint, no Keychain) and how full the session's context is.
/// The helper saves one per session under `statusline/`; the app reads the newest.
public struct StatuslineFeed: Codable, Equatable, Sendable {
    public struct Limit: Codable, Equatable, Sendable {
        public var usedPercent: Double
        public var resetsAt: Date
    }

    public var at: Date
    public var sessionId: String
    public var fiveHour: Limit?
    public var sevenDay: Limit?
    /// 0...100, as Claude Code reports it for the model's real window.
    public var contextPercent: Double?
    public var contextSize: Int?

    public init(at: Date, sessionId: String, fiveHour: Limit? = nil, sevenDay: Limit? = nil,
                contextPercent: Double? = nil, contextSize: Int? = nil) {
        self.at = at
        self.sessionId = sessionId
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.contextPercent = contextPercent
        self.contextSize = contextSize
    }

    /// Reads the status line JSON. `rate_limits` only appears for Pro/Max plans after a session's first
    /// reply, and each window may be missing on its own.
    public init?(json: [String: Any], now: Date) {
        guard let id = json["session_id"] as? String, !id.isEmpty else { return nil }
        at = now
        sessionId = id
        func limit(_ key: String) -> Limit? {
            guard let w = (json["rate_limits"] as? [String: Any])?[key] as? [String: Any],
                  let used = (w["used_percentage"] as? NSNumber)?.doubleValue,
                  let resets = (w["resets_at"] as? NSNumber)?.doubleValue else { return nil }
            return Limit(usedPercent: used, resetsAt: Date(timeIntervalSince1970: resets))
        }
        fiveHour = limit("five_hour")
        sevenDay = limit("seven_day")
        let ctx = json["context_window"] as? [String: Any]
        contextPercent = (ctx?["used_percentage"] as? NSNumber)?.doubleValue
        contextSize = (ctx?["context_window_size"] as? NSNumber)?.intValue
    }

    public var hasLimits: Bool { fiveHour != nil || sevenDay != nil }

    /// The Claude snapshot with the 5-hour and weekly windows replaced by this feed's numbers; the other
    /// windows (per-model weeklies, extra usage) stay as the endpoint last reported them.
    public func merged(into snap: ProviderSnapshot?) -> ProviderSnapshot {
        var windows = snap?.windows ?? []
        func put(_ w: UsageWindow) {
            if let i = windows.firstIndex(where: { $0.key == w.key }) { windows[i] = w } else { windows.append(w) }
        }
        if let l = fiveHour {
            put(UsageWindow(key: "five_hour", label: "5h", kind: .fiveHour, usedPercent: l.usedPercent,
                            resetsAt: l.resetsAt, duration: 5 * 3600))
        }
        if let l = sevenDay {
            put(UsageWindow(key: "seven_day", label: "Week", kind: .sevenDay, usedPercent: l.usedPercent,
                            resetsAt: l.resetsAt, duration: 7 * 86400))
        }
        return ProviderSnapshot(provider: .claude, windows: windows, fetchedAt: at, planLabel: snap?.planLabel)
    }
}

public enum StatuslineFiles {
    public static var directory: URL {
        let dir = AureolePaths.appSupport.appendingPathComponent("statusline", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    public static func save(_ feed: StatuslineFeed, in dir: URL = directory) throws {
        let safe = feed.sessionId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let url = dir.appendingPathComponent("\(safe).json")
        try JSONEncoder.aureole.encode(feed).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Every saved feed, dropping files older than a day so the folder stays small.
    public static func loadAll(in dir: URL = directory, now: Date = Date()) -> [StatuslineFeed] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let feed = try? JSONDecoder.aureole.decode(StatuslineFeed.self, from: data) else { return nil }
            if now.timeIntervalSince(feed.at) > 86400 { try? FileManager.default.removeItem(at: url); return nil }
            return feed
        }
    }
}

/// Points Claude Code's `statusLine` at the helper, keeping any status line the user already had: the
/// original setting is saved beside our data and the helper runs it and prints its output.
public enum StatuslineInstaller {
    public static let flag = "--statusline"

    public static var chainURL: URL { AureolePaths.appSupport.appendingPathComponent("statusline-chain.json") }

    public static func isInstalled(settings: [String: Any]) -> Bool {
        guard let cmd = (settings["statusLine"] as? [String: Any])?["command"] as? String else { return false }
        return cmd.contains(HookInstaller.marker) && cmd.contains(flag)
    }

    /// Returns the new settings and, when installing over someone else's status line, that original to save.
    public static func install(settings: [String: Any], helperPath: String) -> (settings: [String: Any], original: [String: Any]?) {
        var out = settings
        let current = settings["statusLine"] as? [String: Any]
        let original = isInstalled(settings: settings) ? nil : current
        var line: [String: Any] = ["type": "command", "command": HookInstaller.quoted(helperPath) + " " + flag]
        // Keep the user's layout preferences (padding, refresh interval) if they had any.
        for key in ["padding", "refreshInterval", "hideVimModeIndicator"] { if let v = current?[key] { line[key] = v } }
        out["statusLine"] = line
        return (out, original)
    }

    /// Puts back the user's original status line, or removes ours when there was none.
    public static func uninstall(settings: [String: Any], original: [String: Any]?) -> [String: Any] {
        var out = settings
        guard isInstalled(settings: settings) else { return out }
        out["statusLine"] = original
        return out
    }

    /// The command the helper should run after recording, from the saved original setting.
    public static func chainedCommand(url: URL = chainURL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = obj["command"] as? String, !cmd.isEmpty, !cmd.contains(HookInstaller.marker) else { return nil }
        return cmd
    }
}
