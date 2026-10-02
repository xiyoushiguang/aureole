import Foundation

public struct Sample: Codable, Equatable, Sendable {
    public let t: Date
    public let provider: ProviderID
    public let key: String
    public let used: Double
    public let resetsAt: Date?

    public init(t: Date, provider: ProviderID, key: String, used: Double, resetsAt: Date?) {
        self.t = t
        self.provider = provider
        self.key = key
        self.used = used
        self.resetsAt = resetsAt
    }
}

public struct Prediction: Equatable, Sendable {
    /// Percentage points consumed per hour over the lookback window.
    public let ratePerHour: Double
    /// When the window hits 100% at the current rate. nil when idle.
    public let exhaustAt: Date?
    public let resetsAt: Date?
    public let basedOnMinutes: Int

    public var exhaustsBeforeReset: Bool {
        guard let exhaustAt, let resetsAt else { return false }
        return exhaustAt < resetsAt
    }
}

public enum Predictor {
    /// Linear fit over the recent samples of one window. Samples from a previous reset cycle are ignored.
    public static func predict(samples: [Sample], now: Date = Date(),
                               lookback: TimeInterval = 30 * 60, minSpan: TimeInterval = 8 * 60) -> Prediction? {
        let recent = samples.filter { $0.t >= now.addingTimeInterval(-lookback) && $0.t <= now }
            .sorted { $0.t < $1.t }
        guard let latest = recent.last else { return nil }
        var cycle = recent.filter { sameCycle($0.resetsAt, latest.resetsAt) }
        // Drop anything before a visible reset (usage dropped sharply).
        if let lastDrop = cycle.indices.reversed().first(where: { i in
            i > 0 && cycle[i].used < cycle[i - 1].used - 5
        }) {
            cycle = Array(cycle[lastDrop...])
        }
        guard cycle.count >= 2, let first = cycle.first else { return nil }
        let span = latest.t.timeIntervalSince(first.t)
        guard span >= minSpan else { return nil }

        let t0 = first.t.timeIntervalSince1970
        let xs = cycle.map { $0.t.timeIntervalSince1970 - t0 }
        let ys = cycle.map { $0.used }
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for i in 0..<xs.count {
            num += (xs[i] - mx) * (ys[i] - my)
            den += (xs[i] - mx) * (xs[i] - mx)
        }
        let slopePerSec = den > 0 ? num / den : 0
        let perHour = max(0, slopePerSec * 3600)
        var exhaustAt: Date?
        if perHour >= 0.5, latest.used < 100 {
            exhaustAt = now.addingTimeInterval((100 - latest.used) / perHour * 3600)
        }
        return Prediction(ratePerHour: perHour, exhaustAt: exhaustAt, resetsAt: latest.resetsAt,
                          basedOnMinutes: Int(span / 60))
    }

    /// Windows this long are forecast from their average pace, not from the last half hour.
    public static let longWindow: TimeInterval = 2 * 86400

    /// "At this week's pace": usage so far divided by time elapsed in the window. A recent-rate fit swings
    /// wildly over days (a busy afternoon says "gone tomorrow", a night says "never"), the average does not.
    /// nil until the window has run `minElapsed`, so a fresh week does not extrapolate from one burst.
    public static func windowPace(_ w: UsageWindow, now: Date = Date(), minElapsed: TimeInterval = 6 * 3600) -> Prediction? {
        guard let reset = w.resetsAt, let d = w.duration, d >= longWindow else { return nil }
        let elapsed = now.timeIntervalSince(reset.addingTimeInterval(-d))
        guard elapsed >= minElapsed, w.usedPercent > 0 else { return nil }
        let perHour = w.usedPercent / (elapsed / 3600)
        let exhaustAt = w.usedPercent < 100 ? now.addingTimeInterval((100 - w.usedPercent) / perHour * 3600) : nil
        return Prediction(ratePerHour: perHour, exhaustAt: exhaustAt, resetsAt: reset, basedOnMinutes: Int(elapsed / 60))
    }

    /// The forecast to show for a window: average pace for long windows, recent fit for short ones.
    public static func forecast(_ w: UsageWindow, samples: [Sample], now: Date = Date()) -> Prediction? {
        if let d = w.duration, d >= longWindow { return windowPace(w, now: now) }
        return predict(samples: samples, now: now)
    }

    public static func sameCycle(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let x?, let y?): return abs(x.timeIntervalSince(y)) < 120
        default: return false
        }
    }
}

/// Suggests which provider to hand new work to when one is nearly drained and the other has headroom.
public struct RoutingHint: Equatable, Sendable {
    public let drained: ProviderID
    public let suggested: ProviderID
    public let drainedPercent: Double
    public let suggestedPercent: Double

    public static func evaluate(_ snapshots: [ProviderID: ProviderSnapshot],
                                drainedAt: Double = 80, headroomBelow: Double = 40) -> RoutingHint? {
        let pairs = ProviderID.allCases.compactMap { id -> (ProviderID, Double)? in
            guard let s = snapshots[id]?.primary else { return nil }
            return (id, s.usedPercent)
        }
        guard pairs.count >= 2 else { return nil }
        guard let worst = pairs.max(by: { $0.1 < $1.1 }), let best = pairs.min(by: { $0.1 < $1.1 }) else { return nil }
        guard worst.0 != best.0, worst.1 >= drainedAt, best.1 <= headroomBelow else { return nil }
        return RoutingHint(drained: worst.0, suggested: best.0, drainedPercent: worst.1, suggestedPercent: best.1)
    }
}
