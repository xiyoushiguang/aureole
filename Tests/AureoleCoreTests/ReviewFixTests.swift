import XCTest
@testable import AureoleCore

/// What the outside review of 0.7.4 turned up: each test is the input that went wrong.
final class ReviewFixTests: XCTestCase {
    override func setUp() { L10n.language = .english }
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func scratch() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aureole-review-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func script(_ body: String) -> ChannelConfig {
        let url = scratch().appendingPathComponent("notify.sh")
        try! ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return ChannelConfig(kind: .shell, target: url.path)
    }

    private var waiting: UsageEvent {
        .sessionWaiting(provider: .claude, name: "a\tname", detail: "printf 'a\\tb'\r\u{01}", since: now, question: false)
    }

    // MARK: A folder's name is text, not script

    func testAFolderNameStaysInsideItsQuotes() {
        // The name that became code: a quote ends the string, the next lines run.
        let name = "/tmp/a\" then\ndo shell script \"x\"\nend if\nif \"b\" is \"b"
        let literal = AppleScriptText.literal(name)
        XCTAssertTrue(literal.hasPrefix("\"") && literal.hasSuffix("\""))
        // Inside, every quote is escaped: none is left to end the string.
        let inside = literal.dropFirst().dropLast()
        var escaped = false
        for ch in inside {
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            XCTAssertNotEqual(ch, "\"", "an unescaped quote would end the string")
        }
        XCTAssertFalse(escaped, "a trailing backslash would swallow the closing quote")
        XCTAssertEqual(AppleScriptText.literal("C:\\"), "\"C:\\\\\"")
        XCTAssertEqual(AppleScriptText.literal("plain"), "\"plain\"")
    }

    func testOnlyDeviceNamesGoIntoAScript() {
        XCTAssertTrue(AppleScriptText.isDeviceName("ttys005"))
        XCTAssertFalse(AppleScriptText.isDeviceName("ttys005\" then"))
        XCTAssertFalse(AppleScriptText.isDeviceName(""))
        XCTAssertFalse(AppleScriptText.isDeviceName("../x"))
    }

    // MARK: A number is not always a time

    func testATimestampOutOfAllRangeIsNotADate() {
        XCTAssertNil(DateParsing.parse(1e100))
        XCTAssertNil(DateParsing.parse(Double.infinity))
        XCTAssertNil(DateParsing.parse(12))
        XCTAssertEqual(DateParsing.parse(1_800_000_000), Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(DateParsing.parse(1_800_000_000_000.0), Date(timeIntervalSince1970: 1_800_000_000))
        // The line that crashed the ledger: read, and left out.
        let line = #"{"type":"assistant","timestamp":1e100,"message":{"model":"claude-opus-4","usage":{"input_tokens":5,"output_tokens":7}}}"#
        XCTAssertNil(TranscriptLines.claude(Data(line.utf8)))
    }

    // MARK: Settings that cannot be read are not empty settings

    func testSettingsThatCannotBeReadStopTheWrite() throws {
        let url = scratch().appendingPathComponent("settings.json")
        XCTAssertTrue(try HookInstaller.read(url: url).isEmpty, "no file yet: nothing to keep")
        try #"{"model":"opus","hooks":{}}"#.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try HookInstaller.read(url: url)["model"] as? String, "opus")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        XCTAssertThrowsError(try HookInstaller.read(url: url), "there, but unreadable: do not treat as empty")
    }

    // MARK: Notifications

    func testAWebhookBodyStaysJSONWhateverTheTextHolds() throws {
        let body = ChannelDispatcher.render(ChannelConfig.defaultWebhookTemplate, waiting)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: String])
        XCTAssertEqual(obj["title"], waiting.title)
        XCTAssertEqual(obj["body"], waiting.body)
    }

    func testAScriptThatSaysALotStillEnds() throws {
        // More than a pipe holds, on stderr, then a failure: the words come back, nobody waits for ever.
        let noisy = script("i=0; while [ $i -lt 4000 ]; do echo 'a line of about fifty characters, written to stderr' 1>&2; i=$((i+1)); done; exit 3")
        XCTAssertThrowsError(try ChannelDispatcher.runShell(waiting, noisy, timeout: 20)) { error in
            guard case ChannelDispatchError.shell(let code, let said) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(code, 3)
            XCTAssertTrue(said.contains("written to stderr"))
            XCTAssertLessThan(said.count, 5000, "only the start of what it said is kept")
        }
    }

    func testAScriptThatNeverAnswersIsStopped() {
        let stuck = script("sleep 30")
        let began = Date()
        XCTAssertThrowsError(try ChannelDispatcher.runShell(waiting, stuck, timeout: 1))
        XCTAssertLessThan(Date().timeIntervalSince(began), 8)
    }

    func testAScriptThatDoesNotReadWhatItIsSent() throws {
        // It closes its input and leaves at once; writing to it must not take the app down.
        try ChannelDispatcher.runShell(waiting, script("exec 0<&-; exit 0"), timeout: 10)
        try ChannelDispatcher.runShell(waiting, script("exit 0"), timeout: 10)
    }

    // MARK: What is written down, and what leaves the machine

    func testTheLogIsForThisAccountOnly() throws {
        let url = scratch().appendingPathComponent("aureole.log")
        let log = AureoleLog(url: url, maxBytes: 200)
        log.log("first")
        log.drain()
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        // Filled and moved aside: the new file is private as well.
        for _ in 0..<20 { log.log(String(repeating: "x", count: 40)) }
        log.drain()
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.previousURL.path))
    }

    func testACopiedDiagnosisDoesNotNameTheAccount() {
        XCTAssertEqual(PrivateText.withoutHome("Codex failed: /Users/someone/.codex/auth.json missing", home: "/Users/someone"),
                       "Codex failed: ~/.codex/auth.json missing")
        XCTAssertEqual(PrivateText.withoutHome("nothing to hide", home: "/Users/someone"), "nothing to hide")
    }
}

/// The second batch from the same review.
final class ReviewFixTests2: XCTestCase {
    override func setUp() { L10n.language = .english }
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func scratch() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aureole-review-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: What is approved is what is shown

    func testACommandIsShownWithWhatChangesIt() {
        let plain = ApprovalRequest.fullText(tool: "Bash", input: ["command": "rm -rf build", "description": "Clean", "timeout": 1000])
        XCTAssertEqual(plain, "rm -rf build", "a description and a time limit add nothing to see")
        let outside = ApprovalRequest.fullText(tool: "Bash", input: ["command": "rm -rf build", "dangerouslyDisableSandbox": true])
        XCTAssertTrue(outside.hasPrefix("rm -rf build\n"))
        XCTAssertTrue(outside.contains("dangerouslyDisableSandbox"), "the same command outside the sandbox must not look the same")
        let elsewhere = ApprovalRequest.fullText(tool: "shell", input: ["command": ["bash", "-lc", "make clean all"], "workdir": "/tmp/other"])
        XCTAssertTrue(elsewhere.hasPrefix("bash -lc 'make clean all'\n"), "where one word ends and the next begins stays visible")
        XCTAssertTrue(elsewhere.contains("/tmp/other"))
    }

    func testTwoFoldersWithOneNameAreToldApart() {
        func rule(_ dir: String) -> String? {
            ApprovalRequest.describe(suggestions: [["type": "addDirectories", "directories": [dir], "destination": "session"]])
        }
        XCTAssertNotEqual(rule("/work/a/secrets"), rule("/work/b/secrets"))
        XCTAssertTrue(rule("/work/a/secrets")!.contains("/work/a/secrets"))
    }

    // MARK: Done means done

    func testAScriptThatSaysDoneIsDoneHoweverShort() {
        var lane = AgentSession(provider: .task, sessionId: "task-x", cwd: "", now: now)
        lane.set(.working, at: now)
        lane.turnStartedAt = now
        lane.set(.idle, at: now.addingTimeInterval(5))
        lane.lastEvent = "Stop"
        XCTAssertTrue(SessionBoard.finishedTask(lane))
        var agent = AgentSession(provider: .claude, sessionId: "s", cwd: "", now: now)
        agent.set(.working, at: now)
        agent.turnStartedAt = now
        agent.set(.idle, at: now.addingTimeInterval(5))
        agent.lastEvent = "Stop"
        XCTAssertFalse(SessionBoard.finishedTask(agent), "an agent's five-second reply is still not a finished task")
        agent.set(.working, at: now.addingTimeInterval(10))
        agent.turnStartedAt = now.addingTimeInterval(10)
        agent.set(.idle, at: now.addingTimeInterval(100))
        agent.lastEvent = "Stop"
        XCTAssertTrue(SessionBoard.finishedTask(agent), "ninety seconds of work is")
    }

    // MARK: Switched off means gone

    func testTurningExcerptsOffDropsTheOnesKept() throws {
        let prompt = try XCTUnwrap(HookEvent(json: ["hook_event_name": "UserPromptSubmit", "session_id": "s", "cwd": "/w", "prompt": "Move the tax rules out"]))
        let kept = SessionReducer.apply(prompt, to: nil, now: now, keepPrompt: true)
        XCTAssertNotNil(kept.promptPreview)
        XCTAssertNotNil(kept.firstPrompt)
        let tool = try XCTUnwrap(HookEvent(json: ["hook_event_name": "PreToolUse", "session_id": "s", "cwd": "/w", "tool_name": "Read"]))
        let after = SessionReducer.apply(tool, to: kept, now: now, keepPrompt: false)
        XCTAssertNil(after.promptPreview)
        XCTAssertNil(after.firstPrompt)
    }

    // MARK: Notifications

    func testAnEventWithoutDetailsNamesNoSessionAndNoCommand() {
        let waiting = UsageEvent.sessionWaiting(provider: .claude, name: "Refactor the billing service", detail: "Bash: curl -H 'Authorization: x'", since: now, question: false)
        let quiet = waiting.withoutDetails
        XCTAssertFalse(quiet.title.contains("billing"))
        XCTAssertFalse(quiet.body.contains("curl"))
        XCTAssertTrue(quiet.title.contains("Claude"))
        XCTAssertEqual(quiet.kind, waiting.kind)
        let done = UsageEvent.sessionDone(provider: .codex, name: "Fix the flaky test", took: 600).withoutDetails
        XCTAssertFalse(done.title.contains("flaky"))
        XCTAssertTrue(done.title.contains("Codex"))
    }

    func testAnAlertSentBeforeQuittingIsNotSentAgain() {
        var s = AgentSession(provider: .claude, sessionId: "s", cwd: "", now: now.addingTimeInterval(-600))
        s.set(.working, at: now.addingTimeInterval(-300))
        s.turnStartedAt = now.addingTimeInterval(-300)
        s.set(.idle, at: now.addingTimeInterval(-30))
        s.updatedAt = now.addingTimeInterval(-30)
        s.lastEvent = "Stop"
        let board = SessionBoard.build([s], now: now, alive: { _ in true })
        var first = SessionAlerts(waitingAfter: 120, announceDone: true)
        XCTAssertEqual(first.check(board, now: now, name: { _ in "x" }).count, 1)
        // The app quits and starts again within the ten minutes a finish stays news.
        var again = SessionAlerts(waitingAfter: 120, announceDone: true, sent: first.sent)
        XCTAssertTrue(again.check(board, now: now.addingTimeInterval(20), name: { _ in "x" }).isEmpty)
    }

    // MARK: Headroom

    func testNoOneIsSentToAProviderWhoseWeekIsSpent() {
        func snap(_ id: ProviderID, five: Double, week: Double) -> ProviderSnapshot {
            ProviderSnapshot(provider: id, windows: [
                UsageWindow(key: "five", label: "5h", kind: .fiveHour, usedPercent: five, resetsAt: now.addingTimeInterval(3600), duration: 18000),
                UsageWindow(key: "week", label: "Week", kind: .sevenDay, usedPercent: week, resetsAt: now.addingTimeInterval(86400), duration: 604800),
            ], fetchedAt: now, planLabel: nil)
        }
        XCTAssertNil(RoutingHint.evaluate([.claude: snap(.claude, five: 10, week: 100), .codex: snap(.codex, five: 85, week: 30)]),
                     "Claude's five hours are free, its week is not")
        XCTAssertEqual(RoutingHint.evaluate([.claude: snap(.claude, five: 10, week: 20), .codex: snap(.codex, five: 85, week: 30)])?.suggested, .claude)
        // A week nearly spent is a reason to move, even with five hours to spare.
        XCTAssertEqual(RoutingHint.evaluate([.claude: snap(.claude, five: 10, week: 92), .codex: snap(.codex, five: 20, week: 30)])?.suggested, .codex)
    }

    // MARK: The ledger

    func testATranscriptCutShortIsNotCountedTwice() throws {
        let file = scratch().appendingPathComponent("s1.jsonl")
        func line(_ id: String, _ out: Int, at: String) -> String {
            #"{"type":"assistant","timestamp":"\#(at)","message":{"id":"\#(id)","model":"claude-opus-4","usage":{"input_tokens":0,"output_tokens":\#(out)}}}"# + "\n"
        }
        let m1 = line("m1", 10, at: "2026-11-20T10:00:00Z"), m2 = line("m2", 20, at: "2026-11-20T10:05:00Z")
        try (m1 + m2).write(to: file, atomically: true, encoding: .utf8)
        let src = LedgerScanner.Source(url: file, provider: .claude, session: "s1")
        var ledger = TokenLedger()
        var cursor = LedgerCursor()
        _ = LedgerScanner.read(src, cursor: &cursor, into: &ledger)
        XCTAssertEqual(ledger.buckets.values.reduce(0) { $0 + $1.tally.output }, 30)
        // The file is rewritten shorter, keeping the first message.
        try m1.write(to: file, atomically: true, encoding: .utf8)
        _ = LedgerScanner.read(src, cursor: &cursor, into: &ledger)
        XCTAssertEqual(ledger.buckets.values.reduce(0) { $0 + $1.tally.output }, 30, "what was counted is not counted again")
        // What is written after that is new, and counted.
        try (m1 + line("m3", 5, at: "2026-11-20T10:09:00Z")).write(to: file, atomically: true, encoding: .utf8)
        _ = LedgerScanner.read(src, cursor: &cursor, into: &ledger)
        XCTAssertEqual(ledger.buckets.values.reduce(0) { $0 + $1.tally.output }, 35)
    }

    // MARK: Updating

    private func run(_ script: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "aureole-update"] + args
        try! p.run()
        p.waitUntilExit()
    }

    private func app(_ dir: URL, _ name: String, holding text: String) -> URL {
        let url = dir.appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try! text.write(to: url.appendingPathComponent("Contents/which"), atomically: true, encoding: .utf8)
        return url
    }

    func testAnUpdateThatCannotBeCopiedLeavesTheOldAppWhole() throws {
        let dir = scratch(), fm = FileManager.default
        let installed = app(dir, "Aureole.app", holding: "old"), staged = app(dir, "staged.app", holding: "new")
        let trash = dir.appendingPathComponent("trash.app")
        // One file of the new copy cannot be read: the copy fails part-way.
        let locked = staged.appendingPathComponent("Contents/locked")
        try "x".write(to: locked, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked.path) }
        run(UpdateSwap.script(waitingFor: 0x7FFF_FFF0, open: false), [installed.path, staged.path, trash.path])
        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("Contents/which"), encoding: .utf8), "old")
        XCTAssertFalse(fm.fileExists(atPath: trash.path), "the old app never left its place")
        XCTAssertFalse(fm.fileExists(atPath: installed.path + ".updating"), "half a copy is not left beside the app")
    }

    func testAnUpdateThatCopiesPutsTheNewAppInPlace() throws {
        let dir = scratch(), fm = FileManager.default
        let installed = app(dir, "Aureole.app", holding: "old"), staged = app(dir, "staged.app", holding: "new")
        let trash = dir.appendingPathComponent("trash.app")
        run(UpdateSwap.script(waitingFor: 0x7FFF_FFF0, open: false), [installed.path, staged.path, trash.path])
        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("Contents/which"), encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: trash.appendingPathComponent("Contents/which"), encoding: .utf8), "old")
        XCTAssertFalse(fm.fileExists(atPath: installed.path + ".updating"))
    }
}
