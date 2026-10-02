import Foundation

/// Once a day, asks GitHub for the latest release so nobody stays on an old build without knowing.
/// One unauthenticated GET to api.github.com; nothing about you is sent beyond the User-Agent.
public enum UpdateChecker {
    public static let latestURL = URL(string: "https://api.github.com/repos/xiyoushiguang/aureole/releases/latest")!
    public static let releasesPage = URL(string: "https://github.com/xiyoushiguang/aureole/releases/latest")!

    public struct Release: Equatable, Sendable {
        public let version: String
        public let url: URL
    }

    /// The newer release, or nil when we are current (or the answer is unusable).
    public static func check(current: String = AureoleInfo.version) async -> Release? {
        var req = URLRequest(url: latestURL)
        req.timeoutInterval = 15
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue(AureoleInfo.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else { return nil }
        let url = (obj["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPage
        return isNewer(tag, than: current) ? Release(version: normalized(tag), url: url) : nil
    }

    /// "v0.3.1" vs "0.3.0" → true. A "dev" build never asks to update.
    public static func isNewer(_ tag: String, than current: String) -> Bool {
        let a = parts(normalized(tag)), b = parts(normalized(current))
        guard !a.isEmpty, !b.isEmpty else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func normalized(_ v: String) -> String { v.hasPrefix("v") ? String(v.dropFirst()) : v }

    static func parts(_ v: String) -> [Int] {
        let nums = v.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) } } ?? []
        return nums.contains(nil) ? [] : nums.compactMap { $0 }
    }
}
