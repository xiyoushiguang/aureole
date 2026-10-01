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
}
