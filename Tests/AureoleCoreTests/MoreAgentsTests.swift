import XCTest
@testable import AureoleCore

final class MoreAgentsTests: XCTestCase {
    func testGeminiEventsBecomeClaudeEvents() {
        func run(_ json: [String: Any], _ prior: AgentSession? = nil) -> AgentSession? {
            guard let n = GeminiHooks.normalize(json), let e = HookEvent(json: n) else { return prior }
            return SessionReducer.apply(e, to: prior, now: Date(), provider: .gemini)
        }
        let base: [String: Any] = ["session_id": "g1", "cwd": "/w/app", "transcript_path": "", "timestamp": "2026-10-15T07:00:00Z"]
        var s = run(base.merging(["hook_event_name": "SessionStart", "source": "startup"]) { $1 })
        XCTAssertEqual(s?.provider, .gemini)
        XCTAssertEqual(s?.state, .idle)
        s = run(base.merging(["hook_event_name": "BeforeAgent", "prompt": "Fix the parser\nplease"]) { $1 }, s)
        XCTAssertEqual(s?.state, .working)
        XCTAssertEqual(s?.firstPrompt, "Fix the parser")
        s = run(base.merging(["hook_event_name": "BeforeTool", "tool_name": "run_shell_command",
                              "tool_input": ["command": "npm test"]]) { $1 }, s)
        XCTAssertEqual(s?.lastDetail, "npm test")
        s = run(base.merging(["hook_event_name": "Notification", "notification_type": "ToolPermission",
                              "message": "Tool Shell requires execution", "details": ["type": "exec", "command": "rm -r build"]]) { $1 }, s)
        XCTAssertEqual(s?.state, .waitingPermission)
        XCTAssertEqual(s?.waitingMessage, "Shell: rm -r build")
        s = run(base.merging(["hook_event_name": "AfterTool", "tool_name": "run_shell_command"]) { $1 }, s)
        XCTAssertEqual(s?.state, .working)
        s = run(base.merging(["hook_event_name": "AfterAgent", "prompt_response": "done"]) { $1 }, s)
        XCTAssertEqual(s?.state, .idle)
        XCTAssertEqual(s?.lastEvent, "Stop")
        XCTAssertNil(GeminiHooks.normalize(base.merging(["hook_event_name": "BeforeModel"]) { $1 }))
    }

    func testGeminiHooksUseMilliseconds() {
        let merged = HookInstaller.merge(settings: ["theme": "x"], helperPath: "/h/aureole-hook", install: true,
                                         events: GeminiHooks.events, arguments: " --gemini", millisecondTimeouts: true)
        let hooks = merged["hooks"] as? [String: Any]
        XCTAssertEqual(hooks?.count, GeminiHooks.events.count)
        let first = ((hooks?["BeforeTool"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first
        XCTAssertEqual(first?["timeout"] as? Int, 5000)
        XCTAssertEqual(first?["command"] as? String, "/h/aureole-hook --gemini")
        XCTAssertEqual(HookInstaller.status(settings: merged, events: GeminiHooks.events), .installed(events: GeminiHooks.events.count))
        let removed = HookInstaller.merge(settings: merged, helperPath: "/h/aureole-hook", install: false, events: GeminiHooks.events)
        XCTAssertNil(removed["hooks"])
        XCTAssertEqual(removed["theme"] as? String, "x")
    }

    func testGeminiChatTokens() throws {
        let meta = Data(#"{"sessionId":"abc-123","projectHash":"h","startTime":"2026-10-15T07:00:00Z","lastUpdated":"x","kind":"main"}"#.utf8)
        XCTAssertEqual(TranscriptLines.geminiSession(meta), "abc-123")
        XCTAssertNil(TranscriptLines.geminiSession(Data(#"{"id":"u1","type":"user","content":[]}"#.utf8)))
        let line = Data(#"{"id":"g1","timestamp":"2026-10-15T07:01:00Z","type":"gemini","content":"ok","model":"gemini-2.5-pro","tokens":{"input":1200,"output":80,"cached":200,"thoughts":40,"tool":10,"total":1330}}"#.utf8)
        let (id, call) = try XCTUnwrap(TranscriptLines.gemini(line))
        XCTAssertEqual(id, "g1")
        XCTAssertEqual(call.tally, TokenTally(input: 1010, cacheRead: 200, output: 120))
        XCTAssertEqual(call.model, "gemini-2.5-pro")
        XCTAssertNil(TranscriptLines.gemini(Data(#"{"id":"g2","timestamp":"2026-10-15T07:01:00Z","type":"gemini","content":"…"}"#.utf8)))
    }

    func testGeminiLedgerCountsEachMessageOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let chats = root.appendingPathComponent("myapp/chats")
        try FileManager.default.createDirectory(at: chats.appendingPathComponent("abc-123"), withIntermediateDirectories: true)
        let msg = #"{"id":"g1","timestamp":"2026-10-15T07:01:00Z","type":"gemini","content":"ok","model":"gemini-2.5-flash","tokens":{"input":1000000,"output":0,"cached":0,"thoughts":0,"tool":0,"total":1000000}}"#
        try ([#"{"sessionId":"abc-123","projectHash":"h","startTime":"2026-10-15T07:00:00Z","lastUpdated":"x","kind":"main"}"#,
              #"{"id":"g1","timestamp":"2026-10-15T07:01:00Z","type":"gemini","content":""}"#, msg, msg, #"{"$set":{"lastUpdated":"y"}}"#]
            .joined(separator: "\n") + "\n").write(to: chats.appendingPathComponent("session-2026-10-15T07-00-abc12345.jsonl"), atomically: true, encoding: .utf8)
        try (#"{"sessionId":"sub-9","kind":"subagent"}"# + "\n" + msg.replacingOccurrences(of: "g1", with: "s1") + "\n")
            .write(to: chats.appendingPathComponent("abc-123/sub-9.jsonl"), atomically: true, encoding: .utf8)
        let none = root.appendingPathComponent("none")
        let sources = LedgerScanner.sources(now: Date(), claudeRoot: none, codexRoot: none, geminiRoot: root, opencodeRoot: none)
        XCTAssertEqual(Set(sources.map(\.session)), ["abc-123"])
        var l = TokenLedger()
        LedgerScanner.scan(&l, sources: sources, now: ISO8601DateFormatter().date(from: "2026-10-15T08:00:00Z")!)
        let t = l.totals()["abc-123"]
        XCTAssertEqual(t?.tally.input, 2_000_000)           // the message once, plus the sub-agent's
        XCTAssertEqual(t?.cost ?? 0, 0.6, accuracy: 1e-9)   // gemini-2.5-flash input at $0.30
    }

    func testGeminiPrices() {
        let before = Pricing.day(2026, 11, 30), after = Pricing.day(2026, 12, 2)
        XCTAssertEqual(Pricing.price(model: "gemini-4-argon", at: before), .openAI(2, cached: 0.1, output: 10))
        XCTAssertEqual(Pricing.price(model: "gemini-4-argon", at: after), .openAI(4, cached: 0.2, output: 20))
        XCTAssertEqual(Pricing.price(model: "gemini-2.5-pro", tally: TokenTally(input: 250_000)), .openAI(2.5, cached: 0.25, output: 15))
        XCTAssertEqual(Pricing.price(model: "gemini-2.5-pro", tally: TokenTally(input: 1000)), .openAI(1.25, cached: 0.125, output: 10))
        XCTAssertNil(Pricing.price(model: "gemini-2.5-flash-image"))
        XCTAssertEqual(Pricing.price(model: "gpt-6.1-sol"), .openAI(2, cached: 0.1, output: 10))
        XCTAssertEqual(Pricing.price(model: "gpt-6.1-sol", tally: TokenTally(input: 300_000)), .openAI(4, cached: 0.2, output: 15))
        XCTAssertEqual(Pricing.price(model: "gpt-5.6-terra-2026-09-01", tally: TokenTally(input: 300_000)), .openAI(4, cached: 0.4, output: 18))
    }

    func testOpencodeUsageLine() throws {
        let line = Data(#"{"id":"msg_1","at":1792000000000,"model":"claude-sonnet-5-5","provider":"anthropic","input":100,"output":50,"reasoning":10,"cacheRead":1000,"cacheWrite":200,"cwd":"/w/site"}"#.utf8)
        let (id, call, cwd) = try XCTUnwrap(TranscriptLines.opencode(line))
        XCTAssertEqual(id, "msg_1")
        XCTAssertEqual(cwd, "/w/site")
        XCTAssertEqual(call.tally, TokenTally(input: 100, cacheWrite5m: 200, cacheRead: 1000, output: 60))
        XCTAssertEqual(call.at, Date(timeIntervalSince1970: 1_792_000_000))
    }

    func testOpencodePluginFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("plugins/aureole.js")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try OpencodePlugin.source(helperPath: "/Users/a b/Library/Application Support/Aureole/aureole-hook", usageDir: "/tmp/u\"x")
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(OpencodePlugin.isInstalled(at: url))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains(#"const HELPER = "/Users/a b/Library/Application Support/Aureole/aureole-hook""#))
        XCTAssertTrue(text.contains(#"const USAGE = "/tmp/u\"x""#))
        // Someone else's file with the same name is left alone.
        let other = dir.appendingPathComponent("plugins/other.js")
        try "export const X = 1".write(to: other, atomically: true, encoding: .utf8)
        try OpencodePlugin.remove(at: other)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        try OpencodePlugin.remove(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testOpencodeHeadless() {
        XCTAssertTrue(ProcessTree.isHeadless(arguments: ["/usr/local/bin/opencode", "run", "fix it"]))
        XCTAssertFalse(ProcessTree.isHeadless(arguments: ["/usr/local/bin/opencode", "."]))
        XCTAssertTrue(ProcessTree.isHeadless(arguments: ["node", "/usr/local/bin/gemini", "-p", "hi"]))
    }
}

final class AlwaysLabelTests: XCTestCase {
    func testSessionSuggestionsReadPlainly() {
        L10n.language = .english
        let s: [[String: Any]] = [["type": "addDirectories", "directories": ["/tmp/x/proj"], "destination": "session"],
                                  ["type": "setMode", "mode": "acceptEdits", "destination": "session"]]
        XCTAssertEqual(ApprovalRequest.describe(suggestions: s), "folder proj, accept edits (this session)")
        let saved: [[String: Any]] = [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "npm test:*"]],
                                       "behavior": "allow", "destination": "localSettings"]]
        XCTAssertEqual(ApprovalRequest.describe(suggestions: saved), "Bash(npm test:*)")
    }
}

final class BugScanFixTests: XCTestCase {
    func testResumedCodexRolloutInOldFolderIsScanned() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let old = root.appendingPathComponent("2026/09/01")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let file = old.appendingPathComponent("rollout-2026-09-01T10-00-00-01a00000-0000-7000-8000-000000000001.jsonl")
        try Data("{}\n".utf8).write(to: file)                    // touched now: the thread was resumed today
        let none = root.appendingPathComponent("none")
        let now = Date()
        func sources(_ known: Set<String>) -> [LedgerScanner.Source] {
            LedgerScanner.sources(now: now, claudeRoot: none, codexRoot: root, geminiRoot: none, opencodeRoot: none, known: known)
        }
        XCTAssertTrue(sources([]).isEmpty)                         // the day folders scanned are only the recent ones
        let found = sources([file.path])
        XCTAssertEqual(found.map(\.session), ["01a00000-0000-7000-8000-000000000001"])
        XCTAssertEqual(found.first?.provider, .codex)
        // An old file nobody touched stays out.
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-20 * 86400)], ofItemAtPath: file.path)
        XCTAssertTrue(sources([file.path]).isEmpty)
    }

    func testBackfillKeepsDaysWhoseFilesAreGone() {
        var old = TokenLedger()
        old.days["claude|2026-08-01"] = LedgerDay(provider: .claude, day: "2026-08-01", tally: TokenTally(input: 500), cost: 5, unpriced: 0)
        old.days["claude|2026-10-01"] = LedgerDay(provider: .claude, day: "2026-10-01", tally: TokenTally(input: 100), cost: 1, unpriced: 0)
        var fresh = TokenLedger()
        fresh.days["claude|2026-10-01"] = LedgerDay(provider: .claude, day: "2026-10-01", tally: TokenTally(input: 300), cost: 3, unpriced: 0)
        fresh.keepHistory(from: old)
        XCTAssertEqual(fresh.days["claude|2026-08-01"]?.cost, 5)   // files gone: the old total stays
        XCTAssertEqual(fresh.days["claude|2026-10-01"]?.cost, 3)   // re-read: the fuller reading wins
        XCTAssertEqual(LedgerDay(provider: .codex, day: "2026-10-01", tally: TokenTally(), cost: 0, unpriced: 0).id, "codex|2026-10-01")
    }

    func testDoneScriptLaneOutlivesItsProcess() {
        let t0 = Date()
        let s = TaskLaneUpdate(id: "nightly", state: .working).apply(to: nil, now: t0)!
        let done = TaskLaneUpdate(id: "nightly", state: .done).apply(to: s, now: t0.addingTimeInterval(120))!
        XCTAssertTrue(TaskLaneUpdate.keepsAfterExit(done, now: t0.addingTimeInterval(300)))
        XCTAssertFalse(TaskLaneUpdate.keepsAfterExit(done, now: t0.addingTimeInterval(120 + TaskLaneUpdate.doneLinger + 1)))
        XCTAssertFalse(TaskLaneUpdate.keepsAfterExit(s, now: t0.addingTimeInterval(10)))     // still working: leaves with the script
        var claude = done; claude.provider = .claude
        XCTAssertFalse(TaskLaneUpdate.keepsAfterExit(claude, now: t0.addingTimeInterval(300)))
    }

    func testLaneIdsWithDotsDoNotCollide() {
        let dir = URL(fileURLWithPath: "/tmp/x")
        XCTAssertNotEqual(SessionFiles.url(for: "task-a.b", in: dir), SessionFiles.url(for: "task-ab", in: dir))
        XCTAssertEqual(SessionFiles.url(for: "../../etc/passwd", in: dir).deletingLastPathComponent().path, "/tmp/x")
    }
}
