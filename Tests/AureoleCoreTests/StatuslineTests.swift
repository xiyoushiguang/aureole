import XCTest
@testable import AureoleCore

final class StatuslineTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Shape from the Claude Code status line docs: percentages 0–100, resets in epoch seconds.
    func json(limits: Bool = true) -> [String: Any] {
        var j: [String: Any] = ["session_id": "abc-123", "cwd": "/x",
                                "context_window": ["context_window_size": 1_000_000, "used_percentage": 8]]
        if limits {
            j["rate_limits"] = ["five_hour": ["used_percentage": 23.5, "resets_at": 1_800_003_600],
                                "seven_day": ["used_percentage": 41.2, "resets_at": 1_800_300_000]]
        }
        return j
    }

    func testParsesLimitsAndContext() {
        let f = StatuslineFeed(json: json(), now: now)!
        XCTAssertEqual(f.sessionId, "abc-123")
        XCTAssertEqual(f.fiveHour?.usedPercent, 23.5)
        XCTAssertEqual(f.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_800_003_600))
        XCTAssertEqual(f.sevenDay?.usedPercent, 41.2)
        XCTAssertEqual(f.contextPercent, 8)
        XCTAssertEqual(f.contextSize, 1_000_000)
        // Before a session's first reply there are no limits; the context is still useful.
        let early = StatuslineFeed(json: json(limits: false), now: now)!
        XCTAssertFalse(early.hasLimits)
        XCTAssertNil(StatuslineFeed(json: ["cwd": "/x"], now: now))
    }

    func testMergeReplacesOnlyTheWindowsItCarries() {
        let old = ProviderSnapshot(provider: .claude, windows: [
            UsageWindow(key: "five_hour", label: "5h", kind: .fiveHour, usedPercent: 10, resetsAt: now, duration: 5 * 3600),
            UsageWindow(key: "seven_day_opus", label: "Fable wk", kind: .other, usedPercent: 46, resetsAt: now, duration: 7 * 86400),
        ], fetchedAt: now - 600, planLabel: "Max")
        let merged = StatuslineFeed(json: json(), now: now)!.merged(into: old)
        XCTAssertEqual(merged.fetchedAt, now)
        XCTAssertEqual(merged.planLabel, "Max")
        XCTAssertEqual(merged.session?.usedPercent, 23.5)
        XCTAssertEqual(merged.weekly?.usedPercent, 41.2)
        XCTAssertEqual(merged.windows.first { $0.key == "seven_day_opus" }?.usedPercent, 46)   // kept
    }

    func testInstallChainsAnExistingStatusLineAndRemovalRestoresIt() {
        let mine: [String: Any] = ["type": "command", "command": "~/.claude/statusline.sh", "padding": 2]
        let (installed, original) = StatuslineInstaller.install(settings: ["statusLine": mine, "model": "opus"], helperPath: "/A B/aureole-hook")
        let line = installed["statusLine"] as! [String: Any]
        XCTAssertEqual(line["command"] as? String, "\"/A B/aureole-hook\" --statusline")
        XCTAssertEqual(line["padding"] as? Int, 2)
        XCTAssertEqual(installed["model"] as? String, "opus")
        XCTAssertTrue(StatuslineInstaller.isInstalled(settings: installed))
        XCTAssertEqual(original?["command"] as? String, "~/.claude/statusline.sh")
        // Installing twice does not save our own line as the "original".
        XCTAssertNil(StatuslineInstaller.install(settings: installed, helperPath: "/A B/aureole-hook").original)

        let restored = StatuslineInstaller.uninstall(settings: installed, original: original)
        XCTAssertEqual((restored["statusLine"] as? [String: Any])?["command"] as? String, "~/.claude/statusline.sh")
        // With no original, removal leaves no status line at all.
        let (fresh, none) = StatuslineInstaller.install(settings: [:], helperPath: "/h/aureole-hook")
        XCTAssertNil(none)
        XCTAssertNil(StatuslineInstaller.uninstall(settings: fresh, original: nil)["statusLine"])
    }

    func testChainedCommandIgnoresOurOwnCommand() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("chain.json")
        try JSONSerialization.data(withJSONObject: ["command": "echo hi"]).write(to: url)
        XCTAssertEqual(StatuslineInstaller.chainedCommand(url: url), "echo hi")
        try JSONSerialization.data(withJSONObject: ["command": "/x/aureole-hook --statusline"]).write(to: url)
        XCTAssertNil(StatuslineInstaller.chainedCommand(url: url))   // never call ourselves in a loop
    }

    func testSessionNameAndSpendLimit() throws {
        let json: [String: Any] = ["session_id": "abc", "session_name": "Fix login",
                                   "rate_limits": ["spend_limit": ["used_percentage": 42.5, "resets_at": 1_800_000_000,
                                                                   "used_usd": 21.25, "limit_usd": 50, "period": "monthly"]]]
        let feed = try XCTUnwrap(StatuslineFeed(json: json, now: Date()))
        XCTAssertEqual(feed.sessionName, "Fix login")
        XCTAssertEqual(feed.spend?.usedUSD, 21.25)
        XCTAssertTrue(feed.hasLimits)
        let w = try XCTUnwrap(feed.merged(into: nil).windows.first { $0.key == "spend_limit" })
        XCTAssertEqual(w.usedPercent, 42.5)
        XCTAssertEqual(w.limitUSD, 50)
        XCTAssertTrue(w.isSpend)
        // Older Claude Code: percent only.
        let bare = StatuslineFeed(json: ["session_id": "x", "rate_limits": ["spend_limit": ["used_percentage": 3]]], now: Date())
        XCTAssertNil(bare?.spend?.usedUSD)
        XCTAssertEqual(bare?.spend?.usedPercent, 3)
    }
}
