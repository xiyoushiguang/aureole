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
