import Foundation

public enum AureoleInfo {
    public static let version: String = {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String { return v }
        return "dev"
    }()
    public static var userAgent: String { "Aureole/\(version) (macOS)" }
}

enum HTTPClient {
    /// Seconds the server asked us to wait, from a `Retry-After` header (seconds or HTTP-date). Clamped to 30…900.
    static func retryAfter(_ http: HTTPURLResponse) -> TimeInterval? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        var seconds: TimeInterval?
        if let n = Double(raw) {
            seconds = n
        } else {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let d = f.date(from: raw) { seconds = d.timeIntervalSinceNow }
        }
        return seconds.map { min(900, max(30, $0)) }
    }

    static func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.transport("Non-HTTP response")
            }
            return (data, http)
        } catch let e as ProviderError {
            throw e
        } catch {
            throw ProviderError.transport(error.localizedDescription)
        }
    }
}

public enum DateParsing {
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Accepts epoch seconds, epoch milliseconds, or ISO-8601 strings.
    public static func parse(_ value: Any?) -> Date? {
        switch value {
        case let d as Double: return fromEpoch(d)
        case let i as Int: return fromEpoch(Double(i))
        case let n as NSNumber: return fromEpoch(n.doubleValue)
        case let s as String:
            if let d = isoFractional.date(from: s) ?? iso.date(from: s) { return d }
            if let d = Double(s) { return fromEpoch(d) }
            return nil
        default: return nil
        }
    }

    private static func fromEpoch(_ v: Double) -> Date? {
        guard v > 0 else { return nil }
        return Date(timeIntervalSince1970: v > 1e11 ? v / 1000 : v)
    }
}

/// Minimal file logger (never log credentials).
public final class AureoleLog: @unchecked Sendable {
    public static let shared = AureoleLog()
    private let queue = DispatchQueue(label: "app.aureole.log")
    public let url: URL
    private let formatter: DateFormatter

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Aureole", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("aureole.log")
        formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    }

    public func log(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            if let h = try? FileHandle(forWritingTo: self.url) {
                h.seekToEndOfFile()
                h.write(line.data(using: .utf8)!)
                try? h.close()
            } else {
                try? line.data(using: .utf8)?.write(to: self.url)
            }
        }
    }
}

public enum AureolePaths {
    public static var appSupport: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Aureole", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }
}

/// Opt-in raw payload dump for bug reports: `defaults write app.aureole.Aureole debugDump -bool true`
/// or AUREOLE_DEBUG=1. Payloads hold usage numbers only, never tokens.
public enum DebugDump {
    public static var enabled: Bool {
        ProcessInfo.processInfo.environment["AUREOLE_DEBUG"] != nil || UserDefaults.standard.bool(forKey: "debugDump")
    }

    public static func write(_ data: Data, name: String) {
        guard enabled else { return }
        let dir = AureolePaths.appSupport.appendingPathComponent("debug", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
