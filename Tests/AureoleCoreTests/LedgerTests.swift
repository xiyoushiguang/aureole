import XCTest
@testable import AureoleCore

final class PricingTests: XCTestCase {
    func testClaudePricesByModel() {
        let t = TokenTally(input: 1_000_000, cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        // Opus 5.5: 4 + 5 + 8 + 0.2 + 20
        XCTAssertEqual(Pricing.cost(model: "claude-opus-5-5", tally: t)!, 37.2, accuracy: 1e-9)
        // A dated id or a context suffix prices like its model; "opus-5" must not swallow "opus-5-5".
        XCTAssertEqual(Pricing.price(model: "claude-opus-5-5[1m]"), Pricing.claude["opus-5-5"])
        XCTAssertEqual(Pricing.price(model: "claude-opus-5-20260301"), Pricing.claude["opus-5"])
        XCTAssertEqual(Pricing.price(model: "claude-sonnet-4-20250514"), Pricing.claude["sonnet-4"])
        XCTAssertEqual(Pricing.price(model: "claude-sonnet-4-5-20250929"), Pricing.claude["sonnet-4-5"])
        XCTAssertNil(Pricing.price(model: "claude-unknown-9"))
    }

    func testHaiku55PricesByPromptLength() {
        let short = TokenTally(input: 50_000, output: 1000)
        let long = TokenTally(input: 10_000, cacheRead: 95_000, output: 1000)
        XCTAssertEqual(Pricing.price(model: "claude-haiku-5-5", tally: short), Pricing.claude["haiku-5-5"])
        XCTAssertEqual(Pricing.price(model: "claude-haiku-5-5", tally: long), Pricing.haiku55Long)
    }

    func testOpenAIExactNamesOnly() {
        XCTAssertEqual(Pricing.price(model: "gpt-5.6-terra"), .openAI(2, cached: 0.2, output: 12))
        XCTAssertEqual(Pricing.price(model: "gpt-5.4-2026-03-05"), Pricing.openAI["gpt-5.4"])
        XCTAssertNil(Pricing.price(model: "gpt-5.5-cyber"))
        XCTAssertNil(Pricing.price(model: "codex-auto-review"))
        // Cache writes cost what input costs at OpenAI.
        XCTAssertEqual(Pricing.cost(model: "gpt-5.5", tally: TokenTally(input: 1_000_000, cacheRead: 1_000_000, output: 1_000_000))!,
                       35.5, accuracy: 1e-9)
    }

    func testShortMoney() {
        XCTAssertEqual(Pricing.short(0.004), "$0")
        XCTAssertEqual(Pricing.short(0.42), "$0.42")
        XCTAssertEqual(Pricing.short(3.24), "$3.2")
        XCTAssertEqual(Pricing.short(67.6), "$68")
    }
}

final class LedgerTests: XCTestCase {
    func line(_ obj: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: obj) }

    func claudeLine(id: String, at: String, input: Int = 2, write: Int = 100, write1h: Int = 100, read: Int = 1000, output: Int = 50,
                    model: String = "claude-opus-5-5") -> Data {
        line(["type": "assistant", "timestamp": at, "isSidechain": false,
              "message": ["id": id, "model": model, "usage": ["input_tokens": input, "cache_creation_input_tokens": write,
                                                               "cache_read_input_tokens": read, "output_tokens": output,
                                                               "cache_creation": ["ephemeral_1h_input_tokens": write1h, "ephemeral_5m_input_tokens": 0]]]])
    }

    func testClaudeLineSplitsCacheWrites() {
        let (id, call) = TranscriptLines.claude(claudeLine(id: "m1", at: "2026-10-14T10:00:00.000Z", write: 300, write1h: 100))!
        XCTAssertEqual(id, "m1")
        XCTAssertEqual(call.tally, TokenTally(input: 2, cacheWrite5m: 200, cacheWrite1h: 100, cacheRead: 1000, output: 50))
        XCTAssertNil(TranscriptLines.claude(line(["type": "user", "message": ["content": "usage"]])))
        XCTAssertNil(TranscriptLines.claude(claudeLine(id: "x", at: "2026-10-14T10:00:00Z", model: "<synthetic>")))
    }

    func testCodexCountsDeltasAndTakesCachedOutOfInput() {
        var cursor = LedgerCursor()
        XCTAssertNil(TranscriptLines.codex(line(["type": "turn_context", "timestamp": "2026-10-14T10:00:00Z",
                                                 "payload": ["model": "gpt-5.6-terra"]]), cursor: &cursor))
        func count(_ input: Int, _ cached: Int, _ output: Int) -> Data {
            line(["type": "event_msg", "timestamp": "2026-10-14T10:01:00Z",
                  "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": input, "cached_input_tokens": cached,
                                                                                     "cache_write_input_tokens": 0, "output_tokens": output]]]])
        }
        let a = TranscriptLines.codex(count(1000, 800, 50), cursor: &cursor)!
        XCTAssertEqual(a.model, "gpt-5.6-terra")
        XCTAssertEqual(a.tally, TokenTally(input: 200, cacheRead: 800, output: 50))
        XCTAssertNil(TranscriptLines.codex(count(1000, 800, 50), cursor: &cursor))   // repeated totals: nothing new
        let b = TranscriptLines.codex(count(1500, 1200, 80), cursor: &cursor)!
        XCTAssertEqual(b.tally, TokenTally(input: 100, cacheRead: 400, output: 30))
    }

    func testScanReadsOnlyWhatIsNewAndSkipsRepeatedMessages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("s1/subagents"), withIntermediateDirectories: true)
        let main = project.appendingPathComponent("s1.jsonl")
        let now = ISO8601DateFormatter().string(from: Date())
        var text = Data()
        text += line(["type": "ai-title", "aiTitle": "Fix the build", "sessionId": "s1"]) + Data("\n".utf8)
        // One message is written as two lines with the same usage; it counts once.
        text += claudeLine(id: "m1", at: now) + Data("\n".utf8) + claudeLine(id: "m1", at: now) + Data("\n".utf8)
        let m2 = claudeLine(id: "m2", at: now)
        text += m2.prefix(30)                                     // half a line still being written
        try text.write(to: main)
        try (claudeLine(id: "sub1", at: now, output: 10) + Data("\n".utf8))
            .write(to: project.appendingPathComponent("s1/subagents/agent-a.jsonl"))

        let sources = LedgerScanner.sources(claudeRoot: root, codexRoot: root.appendingPathComponent("none"))
        XCTAssertEqual(Set(sources.map(\.session)), ["s1"])     // the sub-agent counts to its parent
        var ledger = TokenLedger()
        XCTAssertTrue(LedgerScanner.scan(&ledger, sources: sources))
        XCTAssertEqual(ledger.titles["s1"], "Fix the build")
        XCTAssertEqual(ledger.totals()["s1"]?.tally.output, 60)

        // Finish the half line: only it is read next time.
        let h = try FileHandle(forWritingTo: main)
        try h.seekToEnd()
        try h.write(contentsOf: m2.dropFirst(30) + Data("\n".utf8))
        try h.close()
        XCTAssertTrue(LedgerScanner.scan(&ledger, sources: sources))
        XCTAssertEqual(ledger.totals()["s1"]?.tally.output, 110)
        XCTAssertFalse(LedgerScanner.scan(&ledger, sources: sources))
        let cost = ledger.totals()["s1"]!.cost
        XCTAssertGreaterThan(cost, 0)
    }

    func testPruneDropsOldBuckets() {
        var ledger = TokenLedger()
        let now = Date()
        ledger.add(LedgerCall(at: now.addingTimeInterval(-9 * 86400), model: "claude-opus-5-5", tally: TokenTally(output: 1)), provider: .claude, session: "old")
        ledger.add(LedgerCall(at: now, model: "claude-opus-5-5", tally: TokenTally(output: 1)), provider: .claude, session: "new")
        ledger.titles["old"] = "x"
        ledger.prune(now: now)
        XCTAssertEqual(Set(ledger.buckets.values.map(\.session)), ["new"])
        XCTAssertNil(ledger.titles["old"])
    }
}

final class AttributionTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
    func minute(_ m: Int) -> Int { Int(t0.timeIntervalSince1970 / 60) + m }

    func testRisesAreSplitBySpend() {
        let curve: [(t: Date, used: Double)] = [(at(0), 0), (at(10), 10), (at(20), 16), (at(30), 16)]
        let weights: [Int: [String: Double]] = [
            minute(5): ["a": 3, "b": 1],      // first rise: a 7.5, b 2.5
            minute(15): ["b": 2],              // second rise all b
        ]
        let a = QuotaAttribution.split(curve: curve, weights: weights)!
        XCTAssertEqual(a.shares["a"]!, 7.5, accuracy: 1e-9)
        XCTAssertEqual(a.shares["b"]!, 8.5, accuracy: 1e-9)
        XCTAssertEqual(a.order, ["b", "a"])
        // Stacked bands meet the curve at every point.
        let top = a.stack(at: 2, bands: a.bands()).last!.upper
        XCTAssertEqual(top, 16, accuracy: 1e-9)
    }

    func testRiseWithNoTokensIsOther() {
        let curve: [(t: Date, used: Double)] = [(at(0), 5), (at(30), 9)]
        let a = QuotaAttribution.split(curve: curve, weights: [minute(-60): ["a": 1]])!
        XCTAssertEqual(a.base, 5)
        XCTAssertEqual(a.shares[QuotaAttribution.other], 4)
        XCTAssertEqual(a.bands(), [QuotaAttribution.other])
    }

    func testFallingReadingSqueezesTheStack() {
        let curve: [(t: Date, used: Double)] = [(at(0), 0), (at(10), 10), (at(20), 8)]
        let a = QuotaAttribution.split(curve: curve, weights: [minute(5): ["a": 1]])!
        XCTAssertEqual(a.stack(at: 2, bands: a.bands()).last!.upper, 8, accuracy: 1e-9)
    }

    func testOnlyTheLargestGetTheirOwnBand() {
        var weights: [Int: [String: Double]] = [:]
        for (i, s) in ["a", "b", "c", "d", "e", "f"].enumerated() { weights[minute(1), default: [:]][s] = Double(6 - i) }
        let a = QuotaAttribution.split(curve: [(at(0), 0), (at(2), 21)], weights: weights)!
        XCTAssertEqual(a.bands(), ["a", "b", "c", "d", QuotaAttribution.other])
        let parts = a.stack(at: 1, bands: a.bands())
        XCTAssertEqual(parts.last!.upper - parts.last!.lower, 3, accuracy: 1e-9)   // e + f
    }

    func testSceneDrawsBandsUpToTheCurve() {
        let now = Date()
        let window = UsageWindow(key: "five_hour", label: "5h", kind: .fiveHour, usedPercent: 30,
                                 resetsAt: now.addingTimeInterval(3 * 3600), duration: 5 * 3600)
        let samples = [Sample(t: now.addingTimeInterval(-3600), provider: .claude, key: "five_hour", used: 10, resetsAt: window.resetsAt)]
        let m = Int(now.timeIntervalSince1970 / 60)
        let weights: [Int: [String: Double]] = [m - 100: ["a": 1], m - 30: ["b": 1]]
        let scene = HorizonScene(layout: .band, now: now, window: window, samples: samples, prediction: nil,
                                 sessions: SessionBoard(), weights: weights)
        XCTAssertEqual(scene.attribution?.shares["a"] ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(scene.attribution?.shares["b"] ?? 0, 20, accuracy: 1e-9)
        XCTAssertEqual(scene.bands.map(\.key), ["b", "a"])
        // The top band's upper edge at "now" is the current point.
        let top = scene.bands.first { $0.key == "a" }!
        let upperNow = top.polygon[top.polygon.count / 2 - 1]
        XCTAssertEqual(upperNow.x, scene.current!.x, accuracy: 0.01)
    }
}

final class TaskLaneTests: XCTestCase {
    func testParse() throws {
        let u = try TaskLaneUpdate.parse(["--lane", "nightly", "--state", "working", "--progress", "40%", "--name", "Nightly"]).get()
        XCTAssertEqual(u.id, "nightly")
        XCTAssertEqual(u.state, .working)
        XCTAssertEqual(u.progress!, 0.4, accuracy: 1e-9)
        XCTAssertEqual(try TaskLaneUpdate.parse(["--lane", "x", "--progress", "0.25"]).get().progress!, 0.25, accuracy: 1e-9)
        XCTAssertEqual(try TaskLaneUpdate.parse(["--lane", "a/../b"]).get().id, "a..b")
        for bad in [["--lane"], ["--lane", "x", "--state", "flying"], ["--lane", "x", "--colour", "red"], ["--lane", "x", "--progress", "lots"]] {
            if case .success = TaskLaneUpdate.parse(bad) { XCTFail("accepted \(bad)") }
        }
    }

    func testLifecycle() throws {
        let t0 = Date()
        var u = try TaskLaneUpdate.parse(["--lane", "build", "--state", "working", "--detail", "step 1"]).get()
        var s = u.apply(to: nil, now: t0)!
        XCTAssertEqual(s.provider, .task)
        XCTAssertEqual(s.sessionId, "task-build")
        XCTAssertEqual(s.state, .working)
        XCTAssertEqual(s.lastTool, "step 1")
        XCTAssertEqual(s.firstPrompt, "build")

        u = try TaskLaneUpdate.parse(["--lane", "build", "--state", "done"]).get()
        s = u.apply(to: s, now: t0.addingTimeInterval(120))!
        XCTAssertTrue(SessionBoard.finishedTask(s))                  // shows with a check and is announced once
        let board = SessionBoard.build([s], now: t0.addingTimeInterval(121), alive: { _ in true })
        XCTAssertEqual(board.done.map(\.sessionId), ["task-build"])

        u = try TaskLaneUpdate.parse(["--lane", "build", "--state", "waiting", "--detail", "needs a password"]).get()
        s = u.apply(to: s, now: t0.addingTimeInterval(130))!
        XCTAssertTrue(s.state.needsYou)
        XCTAssertEqual(s.waitingMessage, "needs a password")

        XCTAssertNil(try TaskLaneUpdate.parse(["--lane", "build", "--state", "end"]).get().apply(to: s, now: t0))
    }
}

final class HookNeighborTests: XCTestCase {
    func testFindsOtherHandlersButNotOurs() {
        let settings: [String: Any] = ["hooks": [
            "PermissionRequest": [["hooks": [["type": "command", "command": "\"/Applications/Agent HUD.app/Contents/MacOS/agenthud-hook\" permission"],
                                             ["type": "command", "command": "/x/aureole-hook"]]]],
            "Stop": [["hooks": [["type": "command", "command": "node /Users/me/.tools/notify.js --done"]]]],
            "PostToolUse": [["hooks": [["type": "command", "command": "prettier --write"]]]],
        ]]
        XCTAssertEqual(HookNeighbors.find(settings: settings), ["agenthud-hook", "node notify.js"])
        XCTAssertEqual(HookNeighbors.find(settings: [:]), [])
    }
}

final class AlwaysAllowTests: XCTestCase {
    func testDescribesOnlyWhatItCanShow() {
        let rules: [[String: Any]] = [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "npm test:*"]],
                                       "behavior": "allow", "destination": "localSettings"]]
        XCTAssertEqual(ApprovalRequest.describe(suggestions: rules), "Bash(npm test:*)")
        XCTAssertNil(ApprovalRequest.describe(suggestions: nil))
        XCTAssertNil(ApprovalRequest.describe(suggestions: [["type": "somethingNew"]]))
        XCTAssertNil(ApprovalRequest.describe(suggestions: [["type": "addRules", "behavior": "deny", "rules": [["toolName": "Bash"]]]]))
    }

    func testAlwaysHandsTheSuggestionsBack() throws {
        let rules: [[String: Any]] = [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "make:*"]], "behavior": "allow",
                                       "destination": "localSettings"]]
        let out = try JSONSerialization.jsonObject(with: Data(ApprovalDecision.always.hookOutput(suggestions: rules).utf8)) as! [String: Any]
        let decision = (out["hookSpecificOutput"] as! [String: Any])["decision"] as! [String: Any]
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        XCTAssertEqual((decision["updatedPermissions"] as? [[String: Any]])?.count, 1)
        // Plain allow never adds a rule, even when suggestions exist.
        let plain = try JSONSerialization.jsonObject(with: Data(ApprovalDecision.allow.hookOutput(suggestions: rules).utf8)) as! [String: Any]
        XCTAssertNil(((plain["hookSpecificOutput"] as! [String: Any])["decision"] as! [String: Any])["updatedPermissions"])
    }
}
