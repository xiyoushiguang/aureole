import XCTest
@testable import AureoleCore

final class SessionTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func event(_ name: String, _ extra: [String: Any] = [:]) -> HookEvent {
        var json: [String: Any] = ["hook_event_name": name, "session_id": "abc-123", "cwd": "/Users/me/proj/shop-api"]
        for (k, v) in extra { json[k] = v }
        return HookEvent(json: json)!
    }

    func testTurnLifecycle() {
        var s = SessionReducer.apply(event("SessionStart"), to: nil, now: t0)
        XCTAssertEqual(s.state, .idle)
        XCTAssertEqual(s.projectName, "shop-api")
        s = SessionReducer.apply(event("UserPromptSubmit", ["prompt": "fix the\nrefund bug"]), to: s, now: t0 + 1)
        XCTAssertEqual(s.state, .working)
        XCTAssertEqual(s.turns, 1)
        XCTAssertEqual(s.promptPreview, "fix the")
        s = SessionReducer.apply(event("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "npm test\n", "description": "Run tests"]]), to: s, now: t0 + 2)
        XCTAssertEqual(s.lastTool, "Bash")
        XCTAssertEqual(s.lastDetail, "Run tests")
        s = SessionReducer.apply(event("Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"]), to: s, now: t0 + 3)
        XCTAssertEqual(s.state, .waitingPermission)
        XCTAssertEqual(s.stateSince, t0 + 3)
        XCTAssertTrue(s.state.needsYou)
        s = SessionReducer.apply(event("PostToolUse", ["tool_name": "Bash"]), to: s, now: t0 + 9)
        XCTAssertEqual(s.state, .working)
        XCTAssertNil(s.waitingMessage)
        s = SessionReducer.apply(event("Stop"), to: s, now: t0 + 20)
        XCTAssertEqual(s.state, .idle)
        s = SessionReducer.apply(event("SessionEnd", ["reason": "exit"]), to: s, now: t0 + 30)
        XCTAssertEqual(s.state, .ended)
    }

    func testQuestionAndPermissionRequest() {
        var s = SessionReducer.apply(event("UserPromptSubmit", ["prompt": "x"]), to: nil, now: t0)
        s = SessionReducer.apply(event("PreToolUse", ["tool_name": "AskUserQuestion",
                                                      "tool_input": ["questions": [["question": "Which library should we use?"]]]]), to: s, now: t0 + 1)
        XCTAssertEqual(s.state, .waitingInput)
        XCTAssertEqual(s.waitingMessage, "Which library should we use?")
        s = SessionReducer.apply(event("PermissionRequest", ["tool_name": "Edit", "tool_input": ["file_path": "/a/b/Handler.swift"]]), to: s, now: t0 + 2)
        XCTAssertEqual(s.state, .waitingPermission)
        XCTAssertEqual(s.waitingMessage, "Edit: Handler.swift")
    }

    func testPromptCanBeLeftOut() {
        let s = SessionReducer.apply(event("UserPromptSubmit", ["prompt": "secret plan"]), to: nil, now: t0, keepPrompt: false)
        XCTAssertNil(s.promptPreview)
    }

    func testBoardGroupsAndDropsDeadOrStale() {
        var a = SessionReducer.apply(event("UserPromptSubmit", ["prompt": "x"]), to: nil, now: t0)
        a.sessionId = "a"
        var b = SessionReducer.apply(event("Notification", ["notification_type": "permission_prompt"]), to: nil, now: t0 - 60)
        b.sessionId = "b"
        var c = SessionReducer.apply(event("Notification", ["notification_type": "permission_prompt"]), to: nil, now: t0 - 10)
        c.sessionId = "c"
        var dead = SessionReducer.apply(event("Stop"), to: nil, now: t0)
        dead.sessionId = "dead"
        var stale = SessionReducer.apply(event("Stop"), to: nil, now: t0 - 7 * 3600)
        stale.sessionId = "stale"
        let board = SessionBoard.build([a, b, c, dead, stale], now: t0) { $0.sessionId != "dead" }
        XCTAssertEqual(board.waiting.map(\.sessionId), ["b", "c"])   // longest wait first
        XCTAssertEqual(board.working.map(\.sessionId), ["a"])
        XCTAssertEqual(board.idle, [])
    }

    func testFilesRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aureole-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var s = SessionReducer.apply(event("UserPromptSubmit", ["prompt": "x"]), to: nil, now: t0)
        s.sessionId = "../weird id"
        try SessionFiles.save(s, in: dir)
        let all = SessionFiles.loadAll(in: dir)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.state, .working)
        XCTAssertFalse(SessionFiles.url(for: s.sessionId, in: dir).lastPathComponent.contains("/"))
    }

    func testHookInstallIsIdempotentAndKeepsOtherHooks() {
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": ["PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "/usr/bin/python3 guard.py"]]]]],
        ]
        let once = HookInstaller.merge(settings: existing, helperPath: "/Users/me/Library/Application Support/Aureole/aureole-hook", install: true)
        let twice = HookInstaller.merge(settings: once, helperPath: "/Users/me/Library/Application Support/Aureole/aureole-hook", install: true)
        XCTAssertEqual(HookInstaller.status(settings: twice), .installed(events: HookInstaller.events.count))
        let pre = twice["hooks"].flatMap { ($0 as? [String: Any])?["PreToolUse"] as? [[String: Any]] } ?? []
        XCTAssertEqual(pre.count, 2, "guard entry kept, ours added exactly once")
        XCTAssertEqual((pre[0]["matcher"] as? String), "Bash")
        let cmd = ((pre[1]["hooks"] as? [[String: Any]])?.first?["command"] as? String) ?? ""
        XCTAssertTrue(cmd.hasPrefix("\""), "paths with spaces are quoted for the shell")
        XCTAssertEqual(twice["model"] as? String, "opus")

        let removed = HookInstaller.merge(settings: twice, helperPath: "", install: false)
        XCTAssertEqual(HookInstaller.status(settings: removed), .notInstalled)
        let preAfter = removed["hooks"].flatMap { ($0 as? [String: Any])?["PreToolUse"] as? [[String: Any]] } ?? []
        XCTAssertEqual(preAfter.count, 1)
        XCTAssertNil((removed["hooks"] as? [String: Any])?["Stop"])
    }

    func testRecentActivityKeepsLastThreeNewestFirst() {
        var s: AgentSession? = nil
        for (i, f) in ["a.swift", "b.swift", "c.swift", "d.swift"].enumerated() {
            s = SessionReducer.apply(event("PreToolUse", ["tool_name": "Edit", "tool_input": ["file_path": "/x/\(f)"]]), to: s, now: t0 + Double(i))
        }
        XCTAssertEqual(s?.recent?.map(\.text), ["Edit · d.swift", "Edit · c.swift", "Edit · b.swift"])
    }

    func testContextTokensFromTranscriptTail() {
        let tail = """
        {"type":"assistant","isSidechain":false,"message":{"role":"assistant","usage":{"input_tokens":10,"cache_creation_input_tokens":200,"cache_read_input_tokens":3000,"output_tokens":50}}}
        {"type":"user","message":{"role":"user","content":"next"}}
        {"type":"assistant","isSidechain":true,"message":{"role":"assistant","usage":{"input_tokens":999999,"cache_read_input_tokens":0}}}
        {"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":2,"cache_creation_input_tokens":2438,"cache_read_input_tokens":486698,"output_tokens":399}}}
        {"type":"ai-title","aiTitle":"Notch workbench progress","sessionId":"abc"}
        {"type":"attachment","note":"\"usage\" mentioned in passing"}
        """
        XCTAssertEqual(TranscriptReader.contextTokens(inTail: Substring(tail)), 489_138)
        XCTAssertEqual(TranscriptReader.summary(inTail: Substring(tail)).title, "Notch workbench progress")
        XCTAssertNil(TranscriptReader.contextTokens(inTail: "not json at all"))
        XCTAssertEqual(TranscriptReader.short(489_138), "489k")
        XCTAssertEqual(TranscriptReader.short(1_240_000), "1.2M")
        XCTAssertEqual(TranscriptReader.short(812), "812")
    }

    func testSpansFollowWorkAndWaits() {
        var s = SessionReducer.apply(event("SessionStart"), to: nil, now: t0)
        XCTAssertEqual(s.spans ?? [], [])
        s = SessionReducer.apply(event("UserPromptSubmit", ["prompt": "x"]), to: s, now: t0 + 10)
        s = SessionReducer.apply(event("PreToolUse", ["tool_name": "Bash"]), to: s, now: t0 + 20)
        XCTAssertEqual(s.spans, [SessionSpan(start: t0 + 10, end: nil, kind: .working)])
        s = SessionReducer.apply(event("Notification", ["notification_type": "permission_prompt"]), to: s, now: t0 + 30)
        s = SessionReducer.apply(event("PreToolUse", ["tool_name": "AskUserQuestion"]), to: s, now: t0 + 35)   // still a wait
        s = SessionReducer.apply(event("PostToolUse", ["tool_name": "Bash"]), to: s, now: t0 + 40)
        s = SessionReducer.apply(event("Stop"), to: s, now: t0 + 50)
        XCTAssertEqual(s.spans, [SessionSpan(start: t0 + 10, end: t0 + 30, kind: .working),
                                 SessionSpan(start: t0 + 30, end: t0 + 40, kind: .waiting),
                                 SessionSpan(start: t0 + 40, end: t0 + 50, kind: .working)])
        // Hours later, the old spans are gone.
        s = SessionReducer.apply(event("UserPromptSubmit", ["prompt": "y"]), to: s, now: t0 + 4 * 3600)
        XCTAssertEqual(s.spans, [SessionSpan(start: t0 + 4 * 3600, end: nil, kind: .working)])
    }

    func testOldFilesWithoutSpansStillDecode() throws {
        let s = SessionReducer.apply(event("Stop"), to: nil, now: t0)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder.aureole.encode(s)) as! [String: Any]
        json["spans"] = nil
        let back = try JSONDecoder.aureole.decode(AgentSession.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(back.spans)
    }

    func testLongTurnThatStoppedIsDoneUntilSeen() {
        var long = SessionReducer.apply(event("UserPromptSubmit", ["prompt": "x"]), to: nil, now: t0)
        XCTAssertEqual(long.turnStartedAt, t0)
        long = SessionReducer.apply(event("Stop"), to: long, now: t0 + 300)
        XCTAssertTrue(SessionBoard.finishedTask(long))
        var quick = SessionReducer.apply(event("UserPromptSubmit", ["prompt": "x"]), to: nil, now: t0)
        quick.sessionId = "quick"
        quick = SessionReducer.apply(event("Stop"), to: quick, now: t0 + 20)
        XCTAssertFalse(SessionBoard.finishedTask(quick))   // a quick reply is not news

        var b = SessionBoard.build([long, quick], now: t0 + 310, alive: { _ in true })
        XCTAssertEqual(b.done.map(\.id), [long.id])
        XCTAssertEqual(b.idle.map(\.id), ["quick"])
        b = SessionBoard.build([long, quick], now: t0 + 310, alive: { _ in true }, seen: { $0.id == long.id })
        XCTAssertTrue(b.done.isEmpty)
        XCTAssertEqual(b.idle.count, 2)
    }

    func testAlertsFireOncePerWaitAndPerFinish() {
        var waiting = SessionReducer.apply(event("Notification", ["notification_type": "permission_prompt", "message": "Bash: npm test"]), to: nil, now: t0)
        waiting.sessionId = "w"
        var done = SessionReducer.apply(event("UserPromptSubmit", ["prompt": "x"]), to: nil, now: t0 - 600)
        done = SessionReducer.apply(event("Stop"), to: done, now: t0)
        var board = SessionBoard.build([waiting, done], now: t0 + 30, alive: { _ in true })
        var alerts = SessionAlerts(waitingAfter: 120, announceDone: true)

        var events = alerts.check(board, now: t0 + 30, name: \.projectName)
        XCTAssertEqual(events.map(\.kind), ["session_done"])               // the wait is too fresh
        events = alerts.check(board, now: t0 + 130, name: \.projectName)
        XCTAssertEqual(events.map(\.kind), ["session_waiting"])
        XCTAssertEqual(alerts.check(board, now: t0 + 400, name: \.projectName), [])   // never twice

        // A new wait on the same session is announced again.
        waiting = SessionReducer.apply(event("PostToolUse"), to: waiting, now: t0 + 500)
        waiting = SessionReducer.apply(event("Notification", ["notification_type": "permission_prompt"]), to: waiting, now: t0 + 600)
        board = SessionBoard.build([waiting], now: t0 + 800, alive: { _ in true })
        XCTAssertEqual(alerts.check(board, now: t0 + 800, name: \.projectName).map(\.kind), ["session_waiting"])

        // Off means off; stale finishes found later are not announced.
        var quiet = SessionAlerts(waitingAfter: nil, announceDone: true)
        board = SessionBoard.build([waiting, done], now: t0 + 3600, alive: { _ in true })
        XCTAssertEqual(quiet.check(board, now: t0 + 3600, name: \.projectName), [])
    }
}
