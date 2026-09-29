import XCTest
@testable import AureoleCore

final class EventTests: XCTestCase {
    override func setUp() { L10n.language = .english }
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func snap(_ used: Double, reset: Date) -> ProviderSnapshot {
        ProviderSnapshot(provider: .claude, windows: [
            UsageWindow(key: "five_hour", label: "5h", kind: .fiveHour, usedPercent: used, resetsAt: reset, duration: 18000),
        ], fetchedAt: now, planLabel: nil)
    }

    func testThresholdFiresOnceThenResetFires() {
        var d = EventDetector(thresholds: [80, 95])
        let r1 = now.addingTimeInterval(3600)
        XCTAssertEqual(d.detect(previous: nil, current: snap(50, reset: r1), prediction: nil, now: now), [])
        let e1 = d.detect(previous: snap(50, reset: r1), current: snap(82, reset: r1), prediction: nil, now: now)
        XCTAssertEqual(e1.map(\.kind), ["threshold"])
        // Same window, still above: no repeat.
        XCTAssertEqual(d.detect(previous: snap(82, reset: r1), current: snap(90, reset: r1), prediction: nil, now: now), [])
        let e2 = d.detect(previous: snap(90, reset: r1), current: snap(96, reset: r1), prediction: nil, now: now)
        XCTAssertEqual(e2.map(\.kind), ["threshold"])
        // New cycle → reset event, thresholds re-armed.
        let r2 = r1.addingTimeInterval(18000)
        let e3 = d.detect(previous: snap(96, reset: r1), current: snap(1, reset: r2), prediction: nil, now: now)
        XCTAssertEqual(e3.map(\.kind), ["reset"])
        let e4 = d.detect(previous: snap(1, reset: r2), current: snap(85, reset: r2), prediction: nil, now: now)
        XCTAssertEqual(e4.map(\.kind), ["threshold"])
    }

    func testForecastEvent() {
        var d = EventDetector()
        let r = now.addingTimeInterval(3600)
        let p = Prediction(ratePerHour: 60, exhaustAt: now.addingTimeInterval(1800), resetsAt: r, basedOnMinutes: 20)
        let e = d.detect(previous: nil, current: snap(60, reset: r), prediction: p, now: now)
        XCTAssertEqual(e.map(\.kind), ["forecast"])
        XCTAssertEqual(d.detect(previous: nil, current: snap(61, reset: r), prediction: p, now: now), [])
    }

    func testWebhookTemplateRendering() throws {
        let w = UsageWindow(key: "five_hour", label: "5h", kind: .fiveHour, usedPercent: 81, resetsAt: nil, duration: nil)
        let cfg = ChannelConfig(kind: .webhook, url: "https://example.com/hook", headers: ["X-Token": "t"])
        let req = try ChannelDispatcher.request(for: .threshold(provider: .claude, window: w, level: 80), config: cfg)
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Token"), "t")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(req.httpBody)) as? [String: String])
        XCTAssertEqual(body["event"], "threshold")
        XCTAssertEqual(body["percent"], "81")
        XCTAssertEqual(body["title"], "Claude 5h window at 80%")
    }

    func testFeishuAndTelegramRequests() throws {
        let w = UsageWindow(key: "seven_day", label: "Week", kind: .sevenDay, usedPercent: 95, resetsAt: nil, duration: nil)
        let ev = UsageEvent.threshold(provider: .codex, window: w, level: 95)
        let feishu = try ChannelDispatcher.request(for: ev, config: ChannelConfig(kind: .feishu, url: "https://open.feishu.cn/open-apis/bot/v2/hook/x"))
        let fb = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(feishu.httpBody)) as? [String: Any])
        XCTAssertEqual(fb["msg_type"] as? String, "text")
        let tg = try ChannelDispatcher.request(for: ev, config: ChannelConfig(kind: .telegram, token: "123:abc", target: "42"))
        XCTAssertEqual(tg.url?.absoluteString, "https://api.telegram.org/bot123:abc/sendMessage")
        XCTAssertThrowsError(try ChannelDispatcher.request(for: ev, config: ChannelConfig(kind: .telegram)))
    }

    func testFormatting() {
        XCTAssertEqual(Formatting.countdown(45), "<1m")
        XCTAssertEqual(Formatting.countdown(2 * 3600 + 13 * 60), "2h 13m")
        XCTAssertEqual(Formatting.countdown(3 * 86400 + 4 * 3600), "3d 4h")
        XCTAssertEqual(Formatting.percent(41.6), "42%")
    }
}

final class RetryAfterTests: XCTestCase {
    func response(_ retryAfter: String?) -> HTTPURLResponse {
        var headers: [String: String] = [:]
        if let retryAfter { headers["Retry-After"] = retryAfter }
        return HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 429, httpVersion: nil, headerFields: headers)!
    }

    func testSecondsAndClamping() {
        XCTAssertEqual(HTTPClient.retryAfter(response("120")), 120)
        XCTAssertEqual(HTTPClient.retryAfter(response("5")), 30)        // floor
        XCTAssertEqual(HTTPClient.retryAfter(response("99999")), 900)   // ceiling
        XCTAssertNil(HTTPClient.retryAfter(response(nil)))
        XCTAssertNil(HTTPClient.retryAfter(response("soon")))
    }

    func testHTTPDate() throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let value = f.string(from: Date().addingTimeInterval(200))
        let parsed = try XCTUnwrap(HTTPClient.retryAfter(response(value)))
        XCTAssertEqual(parsed, 200, accuracy: 3)
    }
}
