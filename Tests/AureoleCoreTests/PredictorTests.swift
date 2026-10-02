import XCTest
@testable import AureoleCore

final class PredictorTests: XCTestCase {
    override func setUp() { L10n.language = .english }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = Date(timeIntervalSince1970: 1_800_000_000 + 2 * 3600)

    func sample(_ minutesAgo: Double, _ used: Double, reset: Date? = nil) -> Sample {
        Sample(t: now.addingTimeInterval(-minutesAgo * 60), provider: .claude, key: "five_hour", used: used, resetsAt: reset ?? self.reset)
    }

    func testSteadyBurnPredictsExhaustion() throws {
        let p = try XCTUnwrap(Predictor.predict(samples: [sample(20, 40), sample(10, 50), sample(0, 60)], now: now))
        XCTAssertEqual(p.ratePerHour, 60, accuracy: 0.01)
        let eta = try XCTUnwrap(p.exhaustAt)
        XCTAssertEqual(eta.timeIntervalSince(now), 40 * 60, accuracy: 1)
        XCTAssertTrue(p.exhaustsBeforeReset)
    }

    func testSlowBurnDoesNotExhaustBeforeReset() throws {
        let p = try XCTUnwrap(Predictor.predict(samples: [sample(30, 10), sample(0, 12)], now: now))
        XCTAssertEqual(p.ratePerHour, 4, accuracy: 0.01)
        XCTAssertFalse(p.exhaustsBeforeReset)
    }

    func testIdleHasNoExhaustion() throws {
        let p = try XCTUnwrap(Predictor.predict(samples: [sample(30, 10), sample(0, 10)], now: now))
        XCTAssertEqual(p.ratePerHour, 0)
        XCTAssertNil(p.exhaustAt)
    }

    func testTooShortSpanIsNil() {
        XCTAssertNil(Predictor.predict(samples: [sample(1, 10), sample(0, 12)], now: now))
    }

    func testSamplesBeforeResetAreIgnored() throws {
        let oldReset = reset.addingTimeInterval(-5 * 3600)
        let p = try XCTUnwrap(Predictor.predict(samples: [
            sample(25, 90, reset: oldReset), sample(20, 95, reset: oldReset),
            sample(10, 2), sample(0, 4),
        ], now: now))
        XCTAssertEqual(p.ratePerHour, 12, accuracy: 0.01)
    }

    func testRoutingHint() {
        func snap(_ p: ProviderID, _ used: Double) -> ProviderSnapshot {
            ProviderSnapshot(provider: p, windows: [UsageWindow(key: "k", label: "5h", kind: .fiveHour, usedPercent: used, resetsAt: nil, duration: nil)], fetchedAt: now, planLabel: nil)
        }
        let hint = RoutingHint.evaluate([.claude: snap(.claude, 85), .codex: snap(.codex, 20)])
        XCTAssertEqual(hint?.suggested, .codex)
        XCTAssertNil(RoutingHint.evaluate([.claude: snap(.claude, 85), .codex: snap(.codex, 60)]))
        XCTAssertNil(RoutingHint.evaluate([.claude: snap(.claude, 30), .codex: snap(.codex, 20)]))
    }

    func testWeeklyForecastUsesTheWeeksAveragePace() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Two days into a seven-day window with 40% used: 20%/day, so 60% more takes 3 days, two days before the reset.
        let w = UsageWindow(key: "seven_day", label: "Week", kind: .sevenDay, usedPercent: 40,
                            resetsAt: now.addingTimeInterval(5 * 86400), duration: 7 * 86400)
        let p = Predictor.windowPace(w, now: now)!
        XCTAssertEqual(p.ratePerHour * 24, 20, accuracy: 1e-9)
        XCTAssertEqual(p.exhaustAt!.timeIntervalSince(now), 3 * 86400, accuracy: 1)
        XCTAssertTrue(p.exhaustsBeforeReset)
        // A fresh week does not extrapolate from one burst; short windows are not paced this way.
        let fresh = UsageWindow(key: "seven_day", label: "Week", kind: .sevenDay, usedPercent: 10,
                                resetsAt: now.addingTimeInterval(7 * 86400 - 3600), duration: 7 * 86400)
        XCTAssertNil(Predictor.windowPace(fresh, now: now))
        let fiveHour = UsageWindow(key: "five_hour", label: "5h", kind: .fiveHour, usedPercent: 40,
                                   resetsAt: now.addingTimeInterval(3600), duration: 5 * 3600)
        XCTAssertNil(Predictor.windowPace(fiveHour, now: now))

        L10n.language = .english
        let h = HorizonHeadline(provider: .codex, window: w, prediction: p, now: now)
        XCTAssertEqual(h.tone, .warning)
        XCTAssertEqual(h.detail, "Codex weekly used 40% · ≈20%/day")

        var detector = EventDetector()
        let snap = ProviderSnapshot(provider: .codex, windows: [w], fetchedAt: now, planLabel: nil)
        let events = detector.detect(previous: nil, current: snap, prediction: nil, weekly: ["seven_day": p], now: now)
        XCTAssertEqual(events.map(\.kind), ["forecast"])
        XCTAssertEqual(detector.detect(previous: snap, current: snap, prediction: nil, weekly: ["seven_day": p], now: now), [])
    }
}
