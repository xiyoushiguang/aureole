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

    /// A status line that is a step behind must not take the number back down.
    func testStatusLineNeverLowersANumberWithinTheSameWindow() {
        let reset5h = now + 3600, resetWeek = now + 300_000
        func feed(_ five: Double, _ week: Double, at: Date) -> StatuslineFeed {
            StatuslineFeed(at: at, sessionId: "s", fiveHour: .init(usedPercent: five, resetsAt: reset5h),
                           sevenDay: .init(usedPercent: week, resetsAt: resetWeek))
        }
        // What the endpoint just said, with its reset times a second short of the status line's.
        let endpoint = ProviderSnapshot(provider: .claude, windows: [
            UsageWindow(key: "five_hour", label: "5h", kind: .fiveHour, usedPercent: 22, resetsAt: reset5h - 1, duration: 5 * 3600),
            UsageWindow(key: "seven_day", label: "Week", kind: .sevenDay, usedPercent: 18, resetsAt: resetWeek - 1, duration: 7 * 86400),
        ], fetchedAt: now, planLabel: "Max")

        let behind = feed(21, 17, at: now + 5).merged(into: endpoint)
        XCTAssertEqual(behind.session?.usedPercent, 22, "the older, lower number is not taken")
        XCTAssertEqual(behind.weekly?.usedPercent, 18)
        XCTAssertEqual(behind.session?.resetsAt, reset5h - 1, "and nothing else about the window changes")
        XCTAssertEqual(behind.fetchedAt, now + 5)

        let level = feed(22, 18, at: now + 10).merged(into: behind)
        XCTAssertEqual(level.session?.usedPercent, 22)

        let ahead = feed(23, 18, at: now + 20).merged(into: level)
        XCTAssertEqual(ahead.session?.usedPercent, 23, "a higher number is news")
        // Another session's status line, drawn later but last told less.
        XCTAssertEqual(feed(22, 18, at: now + 30).merged(into: ahead).session?.usedPercent, 23)
    }

    func testANewWindowStartsLowAgain() {
        let old = ProviderSnapshot(provider: .claude, windows: [
            UsageWindow(key: "five_hour", label: "5h", kind: .fiveHour, usedPercent: 80, resetsAt: now + 60, duration: 5 * 3600),
        ], fetchedAt: now, planLabel: nil)
        // After the reset the next window is reported with a different reset time: its low number is real.
        let next = StatuslineFeed(at: now + 600, sessionId: "s", fiveHour: .init(usedPercent: 2, resetsAt: now + 600 + 5 * 3600))
        XCTAssertEqual(next.merged(into: old).session?.usedPercent, 2)
        // So is the first number for a window that had no reset time yet (nothing used since the last reset).
        let empty = ProviderSnapshot(provider: .claude, windows: [
            UsageWindow(key: "five_hour", label: "5h", kind: .fiveHour, usedPercent: 0, resetsAt: nil, duration: 5 * 3600),
        ], fetchedAt: now, planLabel: nil)
        XCTAssertEqual(next.merged(into: empty).session?.usedPercent, 2)
    }

    func testAWindowThatWasAlreadyOverIsNotTaken() {
        // A session that has been idle since before the reset still draws its status line with the old window.
        let rolled = ProviderSnapshot(provider: .claude, windows: [
            UsageWindow(key: "five_hour", label: "5h", kind: .fiveHour, usedPercent: 0, resetsAt: nil, duration: 5 * 3600),
            UsageWindow(key: "seven_day", label: "Week", kind: .sevenDay, usedPercent: 30, resetsAt: now + 86400, duration: 7 * 86400),
        ], fetchedAt: now, planLabel: nil)
        let lateDraw = StatuslineFeed(at: now + 120, sessionId: "idle", fiveHour: .init(usedPercent: 91, resetsAt: now - 300),
                                      sevenDay: .init(usedPercent: 31, resetsAt: now + 86400))
        let merged = lateDraw.merged(into: rolled)
        XCTAssertEqual(merged.session?.usedPercent, 0, "last window's 91% is not this window's")
        XCTAssertNil(merged.session?.resetsAt)
        XCTAssertEqual(merged.weekly?.usedPercent, 31, "the weekly window is still running, so its number counts")
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
