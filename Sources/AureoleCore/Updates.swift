import Foundation

/// Once a day, asks GitHub for the latest release so nobody stays on an old build without knowing.
/// One unauthenticated GET to api.github.com; nothing about you is sent beyond the User-Agent.
public enum UpdateChecker {
    public static let latestURL = URL(string: "https://api.github.com/repos/xiyoushiguang/aureole/releases/latest")!
    public static let releasesPage = URL(string: "https://github.com/xiyoushiguang/aureole/releases/latest")!

    public struct Release: Equatable, Sendable {
        public let version: String
        public let url: URL
        /// The notarized disk image attached to the release, for installing in place.
        public var dmgURL: URL?
        public init(version: String, url: URL, dmgURL: URL? = nil) { self.version = version; self.url = url; self.dmgURL = dmgURL }
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
        return isNewer(tag, than: current) ? Release(version: normalized(tag), url: url, dmgURL: dmgAsset(obj)) : nil
    }

    /// The .dmg among a release's assets, served from GitHub only.
    public static func dmgAsset(_ release: [String: Any]) -> URL? {
        let assets = release["assets"] as? [[String: Any]] ?? []
        return assets.compactMap { a -> URL? in
            guard let name = a["name"] as? String, name.hasSuffix(".dmg"),
                  let s = a["browser_download_url"] as? String, let u = URL(string: s),
                  u.scheme == "https", u.host == "github.com" else { return nil }
            return u
        }.first
    }

    /// "TeamIdentifier=49KHQQ9Y53" in `codesign -dv` output → "49KHQQ9Y53"; nil when unsigned or ad hoc.
    public static func teamIdentifier(inCodesignOutput text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("TeamIdentifier=") {
            let id = String(line.dropFirst("TeamIdentifier=".count))
            return id == "not set" || id.isEmpty ? nil : id
        }
        return nil
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

/// The last step of an update: the script that runs after the app has quit and puts the new copy in its place.
public enum UpdateSwap {
    /// `$1` the installed app, `$2` the new copy (already checked), `$3` where the old one goes (the Trash).
    /// Afterwards the app at `$1` is either the old one, whole, or the new one, whole. The new copy is made
    /// beside the app first and moved in only when the copying finished: copying straight into place left half
    /// an app there when it failed part-way (a full disk), with the old one in the Trash.
    public static func script(waitingFor pid: Int32, open: Bool = true) -> String {
        """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        new="$1.updating"
        [ -e "$new" ] && mv "$new" "$3.incomplete"
        if /usr/bin/ditto "$2" "$new"; then
            /usr/bin/xattr -dr com.apple.quarantine "$new" 2>/dev/null
            if mv "$1" "$3"; then
                mv "$new" "$1" || mv "$3" "$1"
            fi
        fi
        [ -e "$new" ] && mv "$new" "$3.incomplete"
        \(open ? "/usr/bin/open \"$1\"" : ":")
        """
    }
}
