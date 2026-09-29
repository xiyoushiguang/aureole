import Foundation

/// Reads the token Codex CLI stores in ~/.codex/auth.json and asks the ChatGPT usage endpoint.
/// Read-only: Aureole never refreshes Codex tokens.
public struct CodexProvider: UsageProvider {
    public let id = ProviderID.codex
    public var codexHome: URL
    public static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public init(codexHome: URL? = nil) {
        if let codexHome {
            self.codexHome = codexHome
        } else if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            self.codexHome = URL(fileURLWithPath: env)
        } else {
            self.codexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        }
    }

    public func fetch() async throws -> ProviderSnapshot {
        let creds = try CodexCredentialReader.read(from: codexHome.appendingPathComponent("auth.json"))
        var req = URLRequest(url: Self.usageURL)
        req.timeoutInterval = 20
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        if let account = creds.accountID {
            req.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(AureoleInfo.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, http) = try await HTTPClient.perform(req)
        switch http.statusCode {
        case 200:
            DebugDump.write(data, name: "codex-usage.json")
            return try CodexUsageDecoder.decode(data)
        case 401, 403:
            throw ProviderError.signedOut(L10n.f("Codex token was rejected (%d). Run `codex` once to refresh your sign-in.", http.statusCode))
        case 429:
            throw ProviderError.rateLimited(retryAfter: HTTPClient.retryAfter(http))
        default:
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw ProviderError.http(http.statusCode, body)
        }
    }
}

public struct CodexCredentials: Sendable {
    public let accessToken: String
    public let accountID: String?
    public let planFromToken: String?
}

public enum CodexCredentialReader {
    public static func read(from url: URL) throws -> CodexCredentials {
        guard let data = try? Data(contentsOf: url) else {
            throw ProviderError.signedOut(L10n.f("No Codex sign-in found (%@ missing). Run `codex` and log in first.", url.path))
        }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> CodexCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.decode("Codex auth.json is not JSON")
        }
        let tokens = root["tokens"] as? [String: Any]
        guard let access = tokens?["access_token"] as? String, !access.isEmpty else {
            if let key = root["OPENAI_API_KEY"] as? String, !key.isEmpty {
                throw ProviderError.signedOut(L10n.t("Codex is using an API key; subscription usage windows need a ChatGPT sign-in (`codex login`)."))
            }
            throw ProviderError.signedOut(L10n.t("Codex auth.json has no access token. Run `codex login`."))
        }
        var account = tokens?["account_id"] as? String
        var plan: String?
        if let idToken = tokens?["id_token"] as? String, let claims = JWT.payload(idToken) {
            let auth = claims["https://api.openai.com/auth"] as? [String: Any]
            if account == nil { account = auth?["chatgpt_account_id"] as? String }
            plan = auth?["chatgpt_plan_type"] as? String
        }
        return CodexCredentials(accessToken: access, accountID: account, planFromToken: plan)
    }
}

public enum CodexUsageDecoder {
    public static func decode(_ data: Data, now: Date = Date()) throws -> ProviderSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.decode("Codex usage payload is not a JSON object")
        }
        var found: [(String, [String: Any])] = []
        collect(root, path: "", into: &found)
        // Shallow (account-level) windows first so model-scoped ones never take the main slots.
        found.sort { ($0.0.split(separator: ".").count, $0.0) < ($1.0.split(separator: ".").count, $1.0) }
        var windows: [UsageWindow] = []
        var seenKinds = Set<String>()
        for (path, dict) in found {
            guard let used = (dict["used_percent"] as? NSNumber)?.doubleValue else { continue }
            let seconds = (dict["limit_window_seconds"] as? NSNumber)?.doubleValue
                ?? (dict["window_seconds"] as? NSNumber)?.doubleValue
            var resets = DateParsing.parse(dict["reset_at"] ?? dict["resets_at"])
            if resets == nil, let after = (dict["reset_after_seconds"] as? NSNumber)?.doubleValue
                ?? (dict["resets_in_seconds"] as? NSNumber)?.doubleValue {
                resets = now.addingTimeInterval(after)
            }
            let (label, kind) = describe(path: path, seconds: seconds)
            let dedupe = "\(kind.rawValue)|\(label)"
            guard !seenKinds.contains(dedupe) else { continue }
            seenKinds.insert(dedupe)
            windows.append(UsageWindow(key: path, label: label, kind: kind, usedPercent: used,
                                       resetsAt: resets, duration: seconds))
        }
        guard !windows.isEmpty else {
            let keys = root.keys.sorted().joined(separator: ",")
            throw ProviderError.decode("no used_percent windows in payload (keys: \(keys))")
        }
        windows.sort { rank($0) < rank($1) }
        let plan = (root["plan_type"] as? String).map(planName)
        return ProviderSnapshot(provider: .codex, windows: windows, fetchedAt: now, planLabel: plan)
    }

    static func planName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "prolite", "pro_lite": return "Pro Lite"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func collect(_ value: Any, path: String, into out: inout [(String, [String: Any])]) {
        if let dict = value as? [String: Any] {
            if dict["used_percent"] != nil { out.append((path, dict)) }
            for (k, v) in dict { collect(v, path: path.isEmpty ? k : "\(path).\(k)", into: &out) }
        } else if let arr = value as? [Any] {
            for (i, v) in arr.enumerated() { collect(v, path: "\(path)[\(i)]", into: &out) }
        }
    }

    static func describe(path: String, seconds: Double?) -> (String, WindowKind) {
        let comps = path.split(separator: ".").map(String.init)
        let leaf = comps.last ?? path
        let isMain = comps.count <= 2
        let isPrimary = leaf == "primary_window" && isMain, isSecondary = leaf == "secondary_window" && isMain
        let scoped = !(isPrimary || isSecondary)
        let prefix = scoped ? modelName(path) + " " : ""
        if let s = seconds {
            if abs(s - 18000) < 3600 { return (prefix + "5h", scoped ? .other : .fiveHour) }
            if abs(s - 604800) < 7200 { return (prefix + (scoped ? "wk" : "Week"), scoped ? .other : .sevenDay) }
            let hours = Int((s / 3600).rounded())
            return (prefix + (hours >= 48 ? "\(hours / 24)d" : "\(hours)h"), .other)
        }
        if isPrimary { return ("5h", .fiveHour) }
        if isSecondary { return ("Week", .sevenDay) }
        return (leaf.replacingOccurrences(of: "_", with: " ").capitalized, .other)
    }

    private static func modelName(_ path: String) -> String {
        let parts = path.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return "model" }
        return parts[parts.count - 2]
    }

    private static func rank(_ w: UsageWindow) -> Int {
        switch w.kind {
        case .fiveHour: return 0
        case .sevenDay: return 1
        case .other: return 2
        }
    }
}

enum JWT {
    static func payload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
