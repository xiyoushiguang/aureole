import XCTest
import CoreGraphics
@testable import AureoleCore

final class HorizonTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let L = HorizonLayout.band

    func window(used: Double, resetIn: TimeInterval, duration: TimeInterval = 5 * 3600) -> UsageWindow {
        UsageWindow(key: "five_hour", label: "5h", kind: .fiveHour, usedPercent: used,
                    resetsAt: now.addingTimeInterval(resetIn), duration: duration)
    }

    func testNowSitsAt38Percent() {
        XCTAssertEqual(L.nowAngle, -3.84, accuracy: 1e-9)
        let top = L.point(0, 1400)
        XCTAssertEqual(top.x, 500, accuracy: 1e-9)
        XCTAssertEqual(top.y, 200, accuracy: 1e-9)
        XCTAssertEqual(L.point(16, 1400).x, 885.9, accuracy: 0.1)    // same x as the D2 board
        XCTAssertEqual(L.x(angle: L.nowAngle), 406.2, accuracy: 0.1)
    }

    func testClockMapsPastAndFuture() {
        let c = HorizonClock(layout: L, now: now, resetsAt: now.addingTimeInterval(3 * 3600))
        XCTAssertEqual(c.angle(now), -3.84, accuracy: 1e-9)
        XCTAssertEqual(c.angle(now - 120 * 60), -16, accuracy: 1e-9)
        XCTAssertEqual(c.angle(now - 60 * 60), -3.84 - 60 * 0.1013, accuracy: 0.01)
        XCTAssertEqual(c.angle(now - 10 * 3600), -16, accuracy: 1e-9)   // clamped
        XCTAssertEqual(c.angle(now + 3 * 3600), 16, accuracy: 1e-9)      // reset is the right edge
        XCTAssertEqual(c.angle(now + 90 * 60), -3.84 + 19.84 / 2, accuracy: 1e-9)
    }

    func testFarResetCapsTheFuture() {
        let c = HorizonClock(layout: L, now: now, resetsAt: now.addingTimeInterval(4 * 86400))
        XCTAssertEqual(c.end, now + 5 * 3600)
        let soon = HorizonClock(layout: L, now: now, resetsAt: now.addingTimeInterval(60))
        XCTAssertEqual(soon.end, now + 30 * 60)
    }

    func testForecastAndDryZone() {
        // 33% used, burning 49%/h, reset in 3h55m: runs out in ~1h22m, well before the reset.
        let w = window(used: 33, resetIn: 3 * 3600 + 55 * 60)
        let p = Prediction(ratePerHour: 49, exhaustAt: now.addingTimeInterval(67.0 / 49 * 3600), resetsAt: w.resetsAt, basedOnMinutes: 30)
        let scene = HorizonScene(layout: L, now: now, window: w, samples: [], prediction: p, sessions: SessionBoard())
        let (from, to) = scene.forecast!
        XCTAssertEqual(from, L.point(-3.84, 1433))
        let exhaustAngle = scene.clock.angle(scene.exhaustAt!)
        XCTAssertEqual(to.x, L.point(exhaustAngle, 1500).x, accuracy: 1e-6)
        XCTAssertEqual(scene.dryFrom!, exhaustAngle, accuracy: 1e-9)
        XCTAssertEqual(scene.dryTo!, 16, accuracy: 1e-9)
        // The window started 1h05m ago, inside the visible past.
        XCTAssertEqual(scene.windowStart, now - 65 * 60)
        XCTAssertEqual(scene.paceLine.count, 7)
        XCTAssertEqual(scene.paceLine.first!, L.point(scene.clock.angle(now - 65 * 60), 1400))
        XCTAssertEqual(scene.paceLine.last!, L.point(16, 1500))
        XCTAssertEqual(scene.ticks.first?.kind, .windowStart)
        XCTAssertEqual(scene.ticks.last?.kind, .reset)
    }

    func testSlowBurnHasNoDryZone() {
        let w = window(used: 20, resetIn: 2 * 3600)
        let p = Prediction(ratePerHour: 5, exhaustAt: now.addingTimeInterval(16 * 3600), resetsAt: w.resetsAt, basedOnMinutes: 30)
        let scene = HorizonScene(layout: L, now: now, window: w, samples: [], prediction: p, sessions: SessionBoard())
        XCTAssertNil(scene.exhaustAt)
        XCTAssertNil(scene.dryFrom)
        XCTAssertEqual(scene.clock.angle(scene.clock.end), 16)
    }

    func testCurveUsesOnlyThisCycle() {
        let w = window(used: 40, resetIn: 3 * 3600 + 10 * 60)
        let samples = [
            Sample(t: now - 90 * 60, provider: .claude, key: "five_hour", used: 90, resetsAt: now - 30 * 60),   // previous cycle
            Sample(t: now - 50 * 60, provider: .claude, key: "five_hour", used: 10, resetsAt: w.resetsAt),
            Sample(t: now - 20 * 60, provider: .claude, key: "five_hour", used: 30, resetsAt: w.resetsAt),
        ]
        let scene = HorizonScene(layout: L, now: now, window: w, samples: samples, prediction: nil, sessions: SessionBoard())
        XCTAssertEqual(scene.curve.count, 4)   // window start, two samples, now
        XCTAssertEqual(scene.curve.last, L.point(-3.84, 1440))
    }

    func testLanesListEverySessionWaitingFirst() {
        func session(_ id: String, _ state: SessionState, spans: [SessionSpan]) -> AgentSession {
            var s = AgentSession(provider: .claude, sessionId: id, cwd: "/x/\(id)", now: now - 3600)
            s.state = state
            s.spans = spans
            return s
        }
        var b = SessionBoard()
        b.working = [session("w", .working, spans: [SessionSpan(start: now - 30 * 60, end: nil, kind: .working)])]
        b.waiting = [session("q", .waitingPermission, spans: [SessionSpan(start: now - 5 * 3600, end: now - 60, kind: .working),
                                                              SessionSpan(start: now - 60, end: nil, kind: .waiting)])]
        b.idle = [session("i", .idle, spans: [SessionSpan(start: now - 100 * 60, end: now - 80 * 60, kind: .working)]),
                  session("new", .idle, spans: [])]
        let scene = HorizonScene(layout: L, now: now, window: nil, samples: [], prediction: nil, sessions: b)
        XCTAssertEqual(scene.lanes.map(\.id), ["q", "w", "i", "new"])
        XCTAssertEqual(scene.lanes.map(\.role), [.waiting, .working, .idle, .idle])
        let q = scene.lanes[0]
        XCTAssertEqual(q.segments.first!.from, -16, accuracy: 1e-9)          // clipped to the left edge
        XCTAssertEqual(q.segments.last!.to, -3.84, accuracy: 1e-9)
        XCTAssertEqual(q.segments.last!.kind, .waiting)
        XCTAssertEqual(scene.lanes[2].segments.first!.to, scene.clock.angle(now - 80 * 60), accuracy: 1e-9)
        XCTAssertTrue(scene.lanes[3].segments.isEmpty)
    }

    func testHeadline() {
        L10n.language = .english
        let w = window(used: 33, resetIn: 4 * 3600)
        let soon = Prediction(ratePerHour: 49, exhaustAt: now.addingTimeInterval(3600), resetsAt: w.resetsAt, basedOnMinutes: 30)
        let h = HorizonHeadline(provider: .claude, window: w, prediction: soon, now: now)
        XCTAssertEqual(h.tone, .warning)
        XCTAssertTrue(h.title.hasPrefix("Runs out "))
        XCTAssertTrue(h.subtitle!.hasPrefix("3h before the "))
        XCTAssertEqual(h.detail, "Claude 5-hour used 33% · ≈49%/h")
        let fine = HorizonHeadline(provider: .claude, window: w, prediction: nil, now: now)
        XCTAssertEqual(fine.tone, .fine)
        XCTAssertTrue(fine.title.hasPrefix("Lasts until the "))
    }

    func testContextGauge() {
        XCTAssertEqual(ContextGauge.fraction(tokens: 100_000), 0.5)
        XCTAssertEqual(ContextGauge.fraction(tokens: 489_000), 0.489)
        XCTAssertEqual(ContextGauge.fraction(tokens: 5_000_000), 1)
    }
}
