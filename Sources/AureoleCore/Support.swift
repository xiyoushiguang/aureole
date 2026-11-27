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
            return try await send(request, on: URLSession.shared)
        } catch let e as URLError where retriesOnFreshSession(e.code) {
            // A long-lived session can hold on to a proxy or route that a VPN or proxy app has since
            // changed (seen as "bad URL" for hours through a local proxy). A fresh session reads the
            // current settings.
            let fresh = URLSession(configuration: .ephemeral)
            defer { fresh.finishTasksAndInvalidate() }
            do {
                return try await send(request, on: fresh)
            } catch {
                throw transportError(error)
            }
        } catch {
            throw transportError(error)
        }
    }

    private static func send(_ request: URLRequest, on session: URLSession) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.transport("Non-HTTP response")
        }
        return (data, http)
    }

    static func retriesOnFreshSession(_ code: URLError.Code) -> Bool {
        [.badURL, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .secureConnectionFailed].contains(code)
    }

    /// Errors that mean the network or a proxy in between is the problem, not the vendor or the sign-in.
    static func isNetworkProblem(_ code: URLError.Code) -> Bool {
        retriesOnFreshSession(code) || [.notConnectedToInternet, .timedOut, .dnsLookupFailed,
                                        .internationalRoamingOff, .dataNotAllowed].contains(code)
    }

    static func transportError(_ error: Error) -> Error {
        if let e = error as? ProviderError { return e }
        if let e = error as? URLError, isNetworkProblem(e.code) {
            return ProviderError.network(e.localizedDescription)
        }
        return ProviderError.transport(error.localizedDescription)
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
        guard v.isFinite, v > 0 else { return nil }
        let seconds = v > 1e11 ? v / 1000 : v
        // Nothing an agent logs is dated before 2001 or after 2100. A number outside that is not a time, and one
        // large enough (1e100 is a legal JSON number) would crash whoever turns the date into whole minutes.
        guard seconds >= 978_307_200, seconds <= 4_102_444_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

/// Text handed to AppleScript. A folder may be called anything, quotes and line breaks included; pasted into a
/// script as it is, such a name ends the string early and what follows it runs as code.
public enum AppleScriptText {
    /// `text` as a string literal: between double quotes, with the two characters that could end it escaped.
    public static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// A terminal device as the system names them ("ttys005"). Anything else is not put in a script at all.
    public static func isDeviceName(_ tty: String) -> Bool {
        !tty.isEmpty && tty.count <= 32 && tty.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}

/// What may leave the machine in a copied diagnosis: the home folder's path carries the account name.
public enum PrivateText {
    public static func withoutHome(_ text: String, home: String = NSHomeDirectory()) -> String {
        home.count > 1 ? text.replacingOccurrences(of: home, with: "~") : text
    }
}

/// Minimal file logger (never log credentials). Once the file passes `maxBytes` it is moved aside as
/// `aureole.log.1`, replacing the one before it, so the two together stay under twice that.
public final class AureoleLog: @unchecked Sendable {
    public static let shared = AureoleLog()
    private let queue = DispatchQueue(label: "app.aureole.log")
    public let url: URL
    public let maxBytes: UInt64
    private let formatter: DateFormatter

    /// The file the current one was moved to when it filled up.
    public var previousURL: URL { url.appendingPathExtension("1") }

    private convenience init() {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Aureole", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.init(url: dir.appendingPathComponent("aureole.log"))
        // The log names sessions and folders: for this account only, including what earlier versions left open.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        for file in [url, previousURL] where fm.fileExists(atPath: file.path) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    init(url: URL, maxBytes: UInt64 = 1_000_000) {
        self.url = url
        self.maxBytes = maxBytes
        formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    }

    public func log(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async { self.write(line) }
    }

    /// Returns once every line logged so far is on disk.
    public func drain() { queue.sync {} }

    /// On `queue`.
    private func write(_ line: String) {
        let fm = FileManager.default
        if let h = try? FileHandle(forWritingTo: url) {
            let size = h.seekToEndOfFile()
            if size >= maxBytes {
                try? h.close()
                try? fm.removeItem(at: previousURL)
                try? fm.moveItem(at: url, to: previousURL)
                start(line)
                return
            }
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            start(line)
        }
    }

    /// A new log file, readable by this account only.
    private func start(_ line: String) {
        FileManager.default.createFile(atPath: url.path, contents: line.data(using: .utf8), attributes: [.posixPermissions: 0o600])
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
