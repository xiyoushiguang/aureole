import XCTest
@testable import AureoleCore

/// Windows that reset while nothing could be read, refusals that end by themselves, a history that is thinned
/// and saved sparingly, and a log that does not grow for ever.
final class QuietTests: XCTestCase {
    override func setUp() { L10n.language = .english }
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func window(_ key: String, _ kind: WindowKind, used: Double, reset: Date?, duration: TimeInterval?) -> UsageWindow {
        UsageWindow(key: key, label: key, kind: kind, usedPercent: used, resetsAt: reset, duration: duration)
    }

    // MARK: - Rolling over

    func testFiveHourWindowIsEmptyAfterItsReset() {
        let w = window("five_hour", .fiveHour, used: 62, reset: t0 + 600, duration: 18000)
        XCTAssertEqual(w.rolledOver(now: t0 + 599), w)
        let after = w.rolledOver(now: t0 + 601)
        XCTAssertEqual(after.usedPercent, 0)
        // The next 5-hour window starts with the next message, so there is no reset time to show yet.
        XCTAssertNil(after.resetsAt)
        XCTAssertEqual(after.key, "five_hour")
    }

    func testWeeklyWindowMovesOnToItsNextReset() {
        let week: TimeInterval = 7 * 86400
        let w = window("seven_day", .sevenDay, used: 41, reset: t0, duration: week)
        let soon = w.rolledOver(now: t0 + 3600)
        XCTAssertEqual(soon.usedPercent, 0)
        XCTAssertEqual(soon.resetsAt, t0 + week)
        // Unread for more than two weeks: the reset shown is the next one still ahead.
        let later = w.rolledOver(now: t0 + 2 * week + 3600)
        XCTAssertEqual(later.resetsAt, t0 + 3 * week)
    }

    func testSpendIsNotForgotten() {
        let w = UsageWindow(key: "extra_usage", label: "Extra", kind: .other, usedPercent: 30, resetsAt: t0, duration: nil,
                            usedUSD: 3, limitUSD: 10)
        XCTAssertEqual(w.rolledOver(now: t0 + 86400), w)
    }

    func testSnapshotRollsOnlyWindowsThatResetSinceTheReading() {
        let week: TimeInterval = 7 * 86400
        let snap = ProviderSnapshot(provider: .codex, windows: [
            window("primary", .fiveHour, used: 80, reset: t0 + 600, duration: 18000),
            window("secondary", .sevenDay, used: 55, reset: t0 + 86400, duration: week),
            // The vendor reported this reset as already past: its number is newer than that reset.
            window("model.weekly", .other, used: 12, reset: t0 - 60, duration: week),
        ], fetchedAt: t0, planLabel: "Plus")
        XCTAssertEqual(snap.rolledOver(now: t0 + 300), snap)
        XCTAssertEqual(snap.nextReset, t0 + 600)

        let rolled = snap.rolledOver(now: t0 + 3600)
        XCTAssertEqual(rolled.windows.map(\.usedPercent), [0, 55, 12])
        XCTAssertNil(rolled.windows[0].resetsAt)
        XCTAssertEqual(rolled.fetchedAt, t0, "nothing new was read")
        XCTAssertEqual(rolled.planLabel, "Plus")
    }

    // MARK: - Refused tokens

    func testRefusalIsAnnouncedOnceAfterTheGracePeriod() {
        var d = EventDetector()
        XCTAssertNil(d.refused(.claude, message: "401", wasWorking: true, now: t0))
        XCTAssertTrue(d.refusalIsFresh(.claude, now: t0 + 60))
        XCTAssertNil(d.refused(.claude, message: "401", wasWorking: true, now: t0 + 6 * 60))
        XCTAssertFalse(d.refusalIsFresh(.claude, now: t0 + 13 * 60))
        guard case .authLost(let p, let m)? = d.refused(.claude, message: "401", wasWorking: true, now: t0 + 13 * 60) else {
            return XCTFail("a refusal that lasted past the grace period should be announced")
        }
        XCTAssertEqual(p, .claude)
        XCTAssertEqual(m, "401")
        XCTAssertNil(d.refused(.claude, message: "401", wasWorking: true, now: t0 + 30 * 60), "once per run")
    }

    func testRefusalThatEndsByItselfIsNeverAnnounced() {
        var d = EventDetector()
        XCTAssertNil(d.refused(.claude, message: "401", wasWorking: true, now: t0))
        XCTAssertNil(d.refused(.claude, message: "401", wasWorking: true, now: t0 + 3 * 60))
        d.refusalsEnded(.claude)
        XCTAssertFalse(d.refusalIsFresh(.claude, now: t0 + 4 * 60))
        // Eight hours later the next token runs out the same way: a new run, with its own grace period.
        XCTAssertNil(d.refused(.claude, message: "401", wasWorking: true, now: t0 + 8 * 3600))
        XCTAssertNil(d.refused(.claude, message: "401", wasWorking: true, now: t0 + 8 * 3600 + 5 * 60))
    }

    func testProviderThatNeverWorkedHasNothingToLose() {
        var d = EventDetector()
        XCTAssertNil(d.refused(.codex, message: "no sign-in", wasWorking: false, now: t0))
        // What it was doing when the run began is what counts, not what later calls say.
        XCTAssertNil(d.refused(.codex, message: "no sign-in", wasWorking: true, now: t0 + 3600))
        // Claude's run is its own.
        XCTAssertNil(d.refused(.claude, message: "401", wasWorking: true, now: t0 + 3600))
        XCTAssertNotNil(d.refused(.claude, message: "401", wasWorking: true, now: t0 + 3600 + 12 * 60))
    }

    func testExpiredTokenReadsAsWaitingNotAsSignedOut() {
        let waiting = ProviderStatus.expired("renews by itself")
        XCTAssertNil(waiting.message, "not a fault")
        XCTAssertEqual(waiting.note, "renews by itself")
        XCTAssertTrue(waiting.isFailing, "its numbers do grow old")
        XCTAssertFalse(ProviderStatus.ok.isFailing)
        XCTAssertEqual(ProviderError.expired("x").errorDescription, "x")
    }

    func testCodexTokenExpiryIsReadFromTheToken() throws {
        func jwt(_ claims: String) -> String {
            let b64 = Data(claims.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return "h.\(b64).s"
        }
        let json = #"{"tokens":{"access_token":"\#(jwt(#"{"exp":1800000600}"#))","account_id":"a"}}"#
        XCTAssertEqual(try CodexCredentialReader.parse(Data(json.utf8)).expiresAt, t0 + 600)
        // A token that is not a JWT, or says nothing about when it ends, is simply tried.
        XCTAssertNil(try CodexCredentialReader.parse(Data(#"{"tokens":{"access_token":"opaque"}}"#.utf8)).expiresAt)
        XCTAssertNil(try CodexCredentialReader.parse(Data(#"{"tokens":{"access_token":"\#(jwt("{}"))"}}"#.utf8)).expiresAt)
    }

    // MARK: - History

    func testOldSamplesAreThinnedToOnePerTenMinutesPerWindow() {
        let now = t0 + 86400
        var samples: [Sample] = []
        // Twelve hours of a reading every minute, for two windows.
        for i in 0..<720 {
            let t = now - 12 * 3600 + Double(i) * 60
            samples.append(Sample(t: t, provider: .claude, key: "five_hour", used: Double(i) / 10, resetsAt: nil))
            samples.append(Sample(t: t, provider: .claude, key: "seven_day", used: Double(i) / 100, resetsAt: nil))
        }
        let thin = HistoryStore.thinned(samples, now: now)
        let edge = now - HistoryStore.fullDetail
        let recent = thin.filter { $0.t >= edge }, old = thin.filter { $0.t < edge }
        XCTAssertEqual(recent.count, 720, "the last six hours keep every reading")
        XCTAssertEqual(old.count, 2 * 36, "before that, one per ten minutes for each window")
        // The one kept is the last of its ten minutes, so the curve still ends each stretch where it stood.
        let firstOld = old.first { $0.key == "five_hour" }
        XCTAssertEqual(firstOld?.used, 0.9)
        XCTAssertEqual(thin.map(\.t), thin.map(\.t).sorted(), "still in time order")
        XCTAssertEqual(HistoryStore.thinned(thin, now: now), thin, "thinning twice changes nothing")
    }

    func testHistoryIsWrittenOnFlushNotOnEveryReading() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aureole-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(url: url, saveInterval: 3600)
        let snap = ProviderSnapshot(provider: .claude, windows: [
            window("five_hour", .fiveHour, used: 10, reset: Date().addingTimeInterval(3600), duration: 18000),
        ], fetchedAt: Date(), planLabel: nil)
        store.append(snap)
        store.append(snap)
        XCTAssertEqual(store.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing is written until the interval is up")
        store.flush()
        let saved = try JSONDecoder.aureole.decode([Sample].self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(HistoryStore(url: url).count, 2, "and it reads back")
    }

    // MARK: - Log

    func testLogMovesAsideWhenItIsFull() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aureole-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AureoleLog(url: dir.appendingPathComponent("a.log"), maxBytes: 200)
        for i in 0..<6 { log.log("line \(i) " + String(repeating: "x", count: 40)) }
        log.drain()
        let current = try String(contentsOf: log.url, encoding: .utf8)
        let previous = try String(contentsOf: log.previousURL, encoding: .utf8)
        XCTAssertTrue(previous.contains("line 0"))
        XCTAssertTrue(current.contains("line 5"))
        XCTAssertFalse(current.contains("line 0"))
        // Nothing is lost at the moment of moving: every line is in one file or the other, once.
        let all = (previous + current).split(separator: "\n")
        XCTAssertEqual(all.count, 6)
        // A second fill replaces the file kept from the first.
        for i in 6..<14 { log.log("line \(i) " + String(repeating: "x", count: 40)) }
        log.drain()
        XCTAssertFalse(try String(contentsOf: log.previousURL, encoding: .utf8).contains("line 0"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 2)
    }

    // MARK: - Busy

    func testBoardIsBusyOnlyWhileAnAgentIsInsideATurn() {
        func session(_ id: String, _ state: SessionState, background: Bool = false) -> AgentSession {
            var s = AgentSession(provider: .claude, sessionId: id, cwd: "/x", now: t0)
            s.set(state, at: t0)
            if background { s.background = true }
            return s
        }
        func board(_ sessions: [AgentSession]) -> SessionBoard {
            SessionBoard.build(sessions, now: t0 + 1, alive: { _ in true })
        }
        XCTAssertFalse(board([]).isBusy)
        XCTAssertFalse(board([session("a", .idle)]).isBusy)
        XCTAssertTrue(board([session("a", .idle), session("b", .working)]).isBusy)
        XCTAssertTrue(board([session("a", .waitingPermission)]).isBusy)
        // An unattended run spends quota too.
        XCTAssertTrue(board([session("n", .working, background: true)]).isBusy)
        XCTAssertFalse(board([session("n", .idle, background: true)]).isBusy)
    }
}
