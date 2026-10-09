import Foundation
import Security

public struct ClaudeCredentials: Sendable {
    public let accessToken: String
    public let expiresAt: Date?
    public let subscriptionType: String?
}

public enum ClaudeCredentialSource: String, Codable, CaseIterable, Sendable {
    /// `/usr/bin/security` is Apple-signed and stable, so a one-time "Always Allow"
    /// survives ad-hoc rebuilds of Aureole. Default.
    case securityCLI
    /// Direct Keychain API. Re-prompts whenever the app's code signature changes.
    case secItem
}

/// Reads the OAuth token Claude Code already stores and asks Anthropic's usage endpoint.
/// Aureole never refreshes or writes the token: refreshing here would invalidate the copy
/// Claude Code holds and force the user to sign in again.
public struct ClaudeProvider: UsageProvider {
    public let id = ProviderID.claude
    public var credentialSource: ClaudeCredentialSource

    public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let betaHeader = "oauth-2025-04-20"

    public init(credentialSource: ClaudeCredentialSource = .securityCLI) {
        self.credentialSource = credentialSource
    }

    public func fetch() async throws -> ProviderSnapshot {
        let creds = try ClaudeCredentialReader.read(source: credentialSource)
        var req = URLRequest(url: Self.usageURL)
        req.timeoutInterval = 20
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(AureoleInfo.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, http) = try await HTTPClient.perform(req)
        switch http.statusCode {
        case 200:
            DebugDump.write(data, name: "claude-usage.json")
            return try ClaudeUsageDecoder.decode(data, plan: creds.subscriptionType)
        case 401, 403:
            throw ProviderError.signedOut(L10n.f("Claude token was rejected (%d). Run `claude` once to refresh your sign-in.", http.statusCode))
        case 429:
            throw ProviderError.rateLimited(retryAfter: HTTPClient.retryAfter(http))
        default:
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw ProviderError.http(http.statusCode, body)
        }
    }
}

public enum ClaudeUsageDecoder {
    public static func decode(_ data: Data, plan: String?, now: Date = Date()) throws -> ProviderSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.decode("Claude usage payload is not a JSON object")
        }
        var windows: [UsageWindow] = []
        var labels = Set<String>()
        func add(_ w: UsageWindow) {
            guard labels.insert(w.label).inserted else { return }
            windows.append(w)
        }
        for (key, value) in root.sorted(by: { $0.key < $1.key }) {
            guard let dict = value as? [String: Any] else { continue }
            guard let raw = dict["utilization"], !(raw is NSNull) else { continue }
            guard let used = (raw as? NSNumber)?.doubleValue else { continue }
            let resets = DateParsing.parse(dict["resets_at"])
            let (label, kind, duration) = describe(key: key)
            // Anthropic ships feature-flag windows under codenames with no reset date; they carry no information.
            // Extra usage (paid overage) has no reset date either, but it is real money, so it stays.
            if kind == .other, resets == nil, key != "extra_usage" { continue }
            add(UsageWindow(key: key, label: label, kind: kind, usedPercent: used, resetsAt: resets, duration: duration))
        }
        // Newer structured list: session / weekly_all / weekly_scoped (per model). Fills gaps and adds per-model weeks.
        if let limits = root["limits"] as? [[String: Any]] {
            for entry in limits {
                guard let used = (entry["percent"] as? NSNumber)?.doubleValue else { continue }
                let group = entry["group"] as? String ?? ""
                let resets = DateParsing.parse(entry["resets_at"])
                let scopeName = ((entry["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                let isSession = group == "session"
                let duration: TimeInterval = isSession ? 5 * 3600 : 7 * 86400
                if let scopeName {
                    add(UsageWindow(key: "limits.\(group).\(scopeName)", label: "\(scopeName) \(isSession ? "5h" : "wk")",
                                    kind: .other, usedPercent: used, resetsAt: resets, duration: duration))
                } else if isSession, windows.first(where: { $0.kind == .fiveHour }) == nil {
                    add(UsageWindow(key: "five_hour", label: "5h", kind: .fiveHour, usedPercent: used, resetsAt: resets, duration: duration))
                } else if group == "weekly", windows.first(where: { $0.kind == .sevenDay }) == nil {
                    add(UsageWindow(key: "seven_day", label: "Week", kind: .sevenDay, usedPercent: used, resetsAt: resets, duration: duration))
                }
            }
        }
        guard !windows.isEmpty else {
            let keys = root.keys.sorted().joined(separator: ",")
            throw ProviderError.decode("no utilization windows in payload (keys: \(keys))")
        }
        windows.sort { order($0) < order($1) }
        return ProviderSnapshot(provider: .claude, windows: windows, fetchedAt: now, planLabel: plan.map(planName))
    }

    static func describe(key: String) -> (String, WindowKind, TimeInterval?) {
        switch key {
        case "five_hour": return ("5h", .fiveHour, 5 * 3600)
        case "seven_day": return ("Week", .sevenDay, 7 * 86400)
        case "extra_usage": return ("Extra", .other, nil)
        default:
            if key.hasPrefix("seven_day_") {
                let model = key.dropFirst("seven_day_".count).replacingOccurrences(of: "_", with: " ")
                return ("\(model.capitalized) wk", .other, 7 * 86400)
            }
            return (key.replacingOccurrences(of: "_", with: " ").capitalized, .other, nil)
        }
    }

    static func order(_ w: UsageWindow) -> Int {
        switch w.kind {
        case .fiveHour: return 0
        case .sevenDay: return 1
        case .other: return w.key == "extra_usage" ? 9 : 2
        }
    }

    static func planName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "max": return "Max"
        case "pro": return "Pro"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        default: return raw.capitalized
        }
    }
}

public enum ClaudeCredentialReader {
    public static let service = "Claude Code-credentials"

    public static func read(source: ClaudeCredentialSource) throws -> ClaudeCredentials {
        let data: Data
        switch source {
        case .securityCLI: data = try readViaSecurityCLI()
        case .secItem: data = try readViaSecItem()
        }
        return try parse(data)
    }

    static func readViaSecurityCLI() throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { throw ProviderError.error("Could not run /usr/bin/security: \(error.localizedDescription)") }
        p.waitUntilExit()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        switch p.terminationStatus {
        case 0:
            var text = String(data: stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.hasPrefix("{"), let hex = Data(hexString: text), let s = String(data: hex, encoding: .utf8) {
                text = s
            }
            return Data(text.utf8)
        case 44:
            throw ProviderError.signedOut(L10n.t("No Claude Code sign-in found. Run `claude` and log in first."))
        default:
            let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if msg.localizedCaseInsensitiveContains("could not be found") {
                throw ProviderError.signedOut(L10n.t("No Claude Code sign-in found. Run `claude` and log in first."))
            }
            throw ProviderError.error(L10n.f("Keychain read denied or failed (exit %d). %@", Int(p.terminationStatus), msg))
        }
    }

    static func readViaSecItem() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw ProviderError.decode("Keychain item has no data") }
            return data
        case errSecItemNotFound:
            throw ProviderError.signedOut(L10n.t("No Claude Code sign-in found. Run `claude` and log in first."))
        default:
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            throw ProviderError.error("Keychain read failed: \(msg)")
        }
    }

    static func parse(_ data: Data) throws -> ClaudeCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.decode("Claude credentials are not JSON")
        }
        let oauth = (root["claudeAiOauth"] as? [String: Any]) ?? root
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw ProviderError.signedOut("Claude Code credentials hold no OAuth token. Sign in with `claude` (subscription login, not an API key).")
        }
        return ClaudeCredentials(accessToken: token,
                                 expiresAt: DateParsing.parse(oauth["expiresAt"]),
                                 subscriptionType: oauth["subscriptionType"] as? String)
    }
}

extension ProviderError {
    static func error(_ m: String) -> ProviderError { .transport(m) }
}

extension Data {
    init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0, !chars.isEmpty else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = Data.nibble(chars[i]), let lo = Data.nibble(chars[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
            i += 2
        }
        self.init(bytes)
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 65...70: return c - 55
        case 97...102: return c - 87
        default: return nil
        }
    }
}
