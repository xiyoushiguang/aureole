import CoreGraphics
import Foundation

/// The "horizon" panel: time runs along the edge of a planet, usage rises off its surface, and each
/// session circles on its own orbit. Everything here is pure geometry so it can be tested without a view.
///
/// Coordinates are canvas points with y pointing down. An angle θ is in degrees, 0 = straight up, positive
/// to the right; `point(θ, r) = (cx + r·sinθ, cy − r·cosθ)`.
public struct HorizonLayout: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public var center: CGPoint
    /// Radius of the planet's surface (0% usage).
    public var horizon: Double
    /// Extra radius for 100% usage.
    public var percentScale: Double
    public var minAngle: Double = -16
    public var maxAngle: Double = 16
    /// "Now" sits this far along the arc, so the future (what matters) gets most of the room.
    public var nowFraction: Double = 0.38
    /// How much past the left side shows.
    public var pastSpan: TimeInterval = 120 * 60
    /// The right side ends at the reset, or this far ahead when the reset is further away (weekly windows).
    public var futureCap: TimeInterval = 5 * 3600
    /// The shortest future the right side will show, so a reset that is minutes away does not stretch everything.
    public var futureFloor: TimeInterval = 30 * 60
    /// Active sessions get orbits between these radii, the ones waiting on you outermost.
    public var orbitInner: Double
    public var orbitOuter: Double
    public var orbitStep: Double
    /// Idle sessions all share this orbit.
    public var idleOrbit: Double
    /// At most this many active sessions get an orbit.
    public var maxOrbits: Int

    public init(width: Double, height: Double, center: CGPoint, horizon: Double, percentScale: Double,
                orbitInner: Double, orbitOuter: Double, orbitStep: Double, idleOrbit: Double, maxOrbits: Int) {
        self.width = width
        self.height = height
        self.center = center
        self.horizon = horizon
        self.percentScale = percentScale
        self.orbitInner = orbitInner
        self.orbitOuter = orbitOuter
        self.orbitStep = orbitStep
        self.idleOrbit = idleOrbit
        self.maxOrbits = maxOrbits
    }

    /// The second layer, drawn on a 1000×600 canvas (scaled to the panel).
    public static let full = HorizonLayout(width: 1000, height: 600, center: CGPoint(x: 500, y: 1870), horizon: 1400,
                                           percentScale: 100, orbitInner: 1540, orbitOuter: 1700, orbitStep: 40,
                                           idleOrbit: 1740, maxOrbits: 8)

    /// The first layer: the same picture on a 580×190 strip, with room for three sessions.
    public static let compact = HorizonLayout(width: 580, height: 190, center: CGPoint(x: 290, y: 1158), horizon: 1000,
                                              percentScale: 64, orbitInner: 1084, orbitOuter: 1124, orbitStep: 20,
                                              idleOrbit: 1144, maxOrbits: 3)

    public var nowAngle: Double { minAngle + nowFraction * (maxAngle - minAngle) }

    public func point(_ degrees: Double, _ r: Double) -> CGPoint {
        let a = degrees * .pi / 180
        return CGPoint(x: center.x + r * sin(a), y: center.y - r * cos(a))
    }

    public func radius(percent: Double) -> Double { horizon + min(105, max(0, percent)) / 100 * percentScale }

    /// Points along an arc, for drawing it as a polyline (fine enough to look round at any panel size).
    public func arc(from a: Double, to b: Double, r: Double, step: Double = 0.2) -> [CGPoint] {
        let n = max(1, Int((abs(b - a) / step).rounded(.up)))
        return (0...n).map { point(a + (b - a) * Double($0) / Double(n), r) }
    }
}

/// Maps wall-clock time to angles: the past two hours on the left of "now", now → right edge on the right.
public struct HorizonClock: Equatable, Sendable {
    public let layout: HorizonLayout
    public let now: Date
    /// Left edge.
    public let start: Date
    /// Right edge.
    public let end: Date

    public init(layout: HorizonLayout, now: Date, resetsAt: Date?) {
        self.layout = layout
        self.now = now
        start = now.addingTimeInterval(-layout.pastSpan)
        let ahead = resetsAt.map { $0.timeIntervalSince(now) } ?? layout.futureCap
        end = now.addingTimeInterval(min(layout.futureCap, max(layout.futureFloor, ahead)))
    }

    public func angle(_ t: Date) -> Double {
        let l = layout
        if t <= now {
            let f = min(1, now.timeIntervalSince(t) / l.pastSpan)
            return l.nowAngle - f * (l.nowAngle - l.minAngle)
        }
        let f = min(1, t.timeIntervalSince(now) / end.timeIntervalSince(now))
        return l.nowAngle + f * (l.maxAngle - l.nowAngle)
    }

    public func contains(_ t: Date) -> Bool { t >= start && t <= end }
}

public struct HorizonTick: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case windowStart, hour, reset }
    public let kind: Kind
    public let date: Date
    public let angle: Double
}

public struct HorizonOrbit: Equatable, Sendable, Identifiable {
    public enum Role: Equatable, Sendable { case waiting, working, idle }
    public struct Arc: Equatable, Sendable {
        public let from: Double
        public let to: Double
        public let kind: SpanKind
    }
    public let session: AgentSession
    public let role: Role
    public let radius: Double
    public let arcs: [Arc]
    /// Where the session's light sits: on the "now" line for active sessions, at the end of its last stretch when idle.
    public let dotAngle: Double?
    public var id: String { session.id }
}

/// Everything the horizon view draws, computed from the current numbers.
public struct HorizonScene: Equatable, Sendable {
    public let layout: HorizonLayout
    public let clock: HorizonClock
    public let window: UsageWindow?
    /// The window started inside the visible past (so it gets a "start" label and the lit band begins there).
    public let windowStart: Date?
    /// Sunrise end of the lit band on the horizon: window start, or the left edge.
    public let litFrom: Double
    /// Usage so far in this window, oldest first; the last point is "now".
    public let curve: [CGPoint]
    public let current: CGPoint?
    /// Dashed line from the current point to where it runs out (or the right edge).
    public let forecast: (CGPoint, CGPoint)?
    public let exhaustAt: Date?
    /// The stretch between running out and the reset, when there is one on screen.
    public let dryFrom: Double?
    public let dryTo: Double?
    /// What steady use would look like: 0% at the window start, 100% at the reset.
    public let paceLine: [CGPoint]
    public let ticks: [HorizonTick]
    public let orbits: [HorizonOrbit]
    /// Guide circles for the orbit radii in use, including the idle one.
    public let guideRadii: [Double]

    public static func == (a: HorizonScene, b: HorizonScene) -> Bool {
        a.layout == b.layout && a.clock == b.clock && a.window == b.window && a.curve == b.curve && a.orbits == b.orbits
            && a.forecast?.0 == b.forecast?.0 && a.forecast?.1 == b.forecast?.1 && a.dryFrom == b.dryFrom
    }

    public var nowAngle: Double { layout.nowAngle }
    public var sun: CGPoint { layout.point(layout.nowAngle, layout.horizon) }
    public var hundredRadius: Double { layout.radius(percent: 100) }

    public init(layout: HorizonLayout, now: Date, window: UsageWindow?, samples: [Sample], prediction: Prediction?,
                sessions: SessionBoard) {
        self.layout = layout
        self.window = window
        let clock = HorizonClock(layout: layout, now: now, resetsAt: window?.resetsAt)
        self.clock = clock

        let start: Date? = {
            guard let r = window?.resetsAt, let d = window?.duration, d > 0 else { return nil }
            return r.addingTimeInterval(-d)
        }()
        windowStart = start.flatMap { $0 > clock.start && $0 <= now ? $0 : nil }
        litFrom = windowStart.map { clock.angle($0) } ?? layout.minAngle

        // Usage curve: this cycle's samples inside the visible past, ending at the live number.
        var curve: [CGPoint] = []
        var current: CGPoint?
        if let window {
            let from = max(clock.start, start ?? clock.start)
            let pts = samples
                .filter { $0.t >= from && $0.t < now && Predictor.sameCycle($0.resetsAt, window.resetsAt) }
                .sorted { $0.t < $1.t }
            if let s = windowStart { curve.append(layout.point(clock.angle(s), layout.horizon)) }
            curve += pts.map { layout.point(clock.angle($0.t), layout.radius(percent: $0.used)) }
            let c = layout.point(layout.nowAngle, layout.radius(percent: window.usedPercent))
            curve.append(c)
            current = c
        }
        self.curve = curve
        self.current = current

        // Forecast at the current burn rate.
        var forecast: (CGPoint, CGPoint)?
        var exhaust: Date?
        var dryFrom: Double?, dryTo: Double?
        if let window, let current, let p = prediction, p.ratePerHour >= 0.5, window.usedPercent < 100 {
            let runsOut = now.addingTimeInterval((100 - window.usedPercent) / p.ratePerHour * 3600)
            let te = min(runsOut, clock.end)
            let pct = min(100, window.usedPercent + p.ratePerHour * te.timeIntervalSince(now) / 3600)
            forecast = (current, layout.point(clock.angle(te), layout.radius(percent: pct)))
            if let reset = window.resetsAt, runsOut < reset {
                exhaust = runsOut
                if runsOut <= clock.end {
                    dryFrom = clock.angle(runsOut)
                    dryTo = clock.angle(min(reset, clock.end))
                }
            }
        }
        self.forecast = forecast
        exhaustAt = exhaust
        self.dryFrom = dryFrom
        self.dryTo = dryTo

        // Steady pace, sampled over the part of the window that is on screen.
        var pace: [CGPoint] = []
        if let start, let reset = window?.resetsAt, reset > start {
            let a = max(start, clock.start), b = min(reset, clock.end)
            if b > a {
                for i in 0...6 {
                    let t = a.addingTimeInterval(b.timeIntervalSince(a) * Double(i) / 6)
                    let pct = t.timeIntervalSince(start) / reset.timeIntervalSince(start) * 100
                    pace.append(layout.point(clock.angle(t), layout.radius(percent: pct)))
                }
            }
        }
        paceLine = pace

        ticks = Self.ticks(clock: clock, windowStart: windowStart, reset: window?.resetsAt)
        let orbits = Self.orbits(sessions, layout: layout, clock: clock)
        self.orbits = orbits
        guideRadii = Self.guides(layout: layout, used: orbits)
    }

    static func ticks(clock: HorizonClock, windowStart: Date?, reset: Date?) -> [HorizonTick] {
        var out: [HorizonTick] = []
        if let s = windowStart { out.append(HorizonTick(kind: .windowStart, date: s, angle: clock.angle(s))) }
        if let r = reset, r <= clock.end { out.append(HorizonTick(kind: .reset, date: r, angle: clock.angle(r))) }
        let labelled = out.map(\.date)
        let cal = Calendar.current
        var t = cal.dateInterval(of: .hour, for: clock.start)?.end ?? clock.start
        while t <= clock.end {
            // Keep hour marks clear of the start/reset labels.
            if !labelled.contains(where: { abs($0.timeIntervalSince(t)) < 20 * 60 }) {
                out.append(HorizonTick(kind: .hour, date: t, angle: clock.angle(t)))
            }
            t = t.addingTimeInterval(3600)
        }
        return out.sorted { $0.angle < $1.angle }
    }

    /// Waiting sessions outermost (longest wait first), then working ones; idle ones share the outer guide.
    static func orbits(_ board: SessionBoard, layout: HorizonLayout, clock: HorizonClock) -> [HorizonOrbit] {
        let active = Array((board.waiting + board.working).prefix(layout.maxOrbits))
        let step = active.count > 1 ? min(layout.orbitStep, (layout.orbitOuter - layout.orbitInner) / Double(active.count - 1)) : layout.orbitStep
        var out: [HorizonOrbit] = []
        for (i, s) in active.enumerated() {
            out.append(HorizonOrbit(session: s, role: s.state.needsYou ? .waiting : .working, radius: layout.orbitOuter - Double(i) * step,
                                    arcs: arcs(s, clock: clock), dotAngle: layout.nowAngle))
        }
        if layout.maxOrbits > 3 {
            for s in board.idle {
                let a = arcs(s, clock: clock)
                guard let last = a.last else { continue }
                out.append(HorizonOrbit(session: s, role: .idle, radius: layout.idleOrbit, arcs: a, dotAngle: last.to))
            }
        }
        return out
    }

    static func arcs(_ s: AgentSession, clock: HorizonClock) -> [HorizonOrbit.Arc] {
        (s.spans ?? []).compactMap { span in
            let end = min(span.end ?? clock.now, clock.now)
            guard end > clock.start else { return nil }
            let a = clock.angle(max(span.start, clock.start)), b = clock.angle(end)
            return HorizonOrbit.Arc(from: min(a, b - 0.15), to: b, kind: span.kind)   // a blip still shows
        }
    }

    static func guides(layout: HorizonLayout, used: [HorizonOrbit]) -> [Double] {
        let n = used.filter { $0.role != .idle }.count
        var radii: [Double] = []
        var r = layout.orbitOuter
        let count = max(n, Int(((layout.orbitOuter - layout.orbitInner) / layout.orbitStep).rounded()) + 1)
        let step = count > 1 ? min(layout.orbitStep, (layout.orbitOuter - layout.orbitInner) / Double(count - 1)) : layout.orbitStep
        for _ in 0..<count { radii.append(r); r -= step }
        if layout.maxOrbits > 3 { radii.insert(layout.idleOrbit, at: 0) }
        return radii
    }
}

/// The words at the top left: the conclusion first, then the numbers behind it.
public struct HorizonHeadline: Equatable, Sendable {
    public enum Tone: Equatable, Sendable { case warning, fine, unknown }
    public let title: String
    public let subtitle: String?
    public let detail: String?
    public let tone: Tone

    public init(provider: ProviderID, window: UsageWindow?, prediction: Prediction?, now: Date = Date()) {
        guard let window else {
            title = provider.displayName
            subtitle = nil
            detail = nil
            tone = .unknown
            return
        }
        let name = provider.displayName + " " + Self.windowName(window)
        var numbers = L10n.f("%@ used %d%%", name, Int(window.usedPercent.rounded()))
        if let p = prediction {
            if p.ratePerHour >= 0.5 { numbers += " · " + L10n.f("≈%d%%/h", Int(p.ratePerHour.rounded())) }
            else if p.basedOnMinutes >= 4 { numbers += " · " + L10n.t("idle") }
        }
        if window.usedPercent >= 100 {
            title = L10n.t("Used up")
            subtitle = window.resetsAt.map { L10n.f("Resets %@", Formatting.resetText($0, now: now)) }
            detail = numbers
            tone = .warning
        } else if let p = prediction, let at = p.exhaustAt, let reset = window.resetsAt, at < reset {
            title = L10n.f("Runs out %@", Formatting.clock(at))
            subtitle = L10n.f("%@ before the %@ reset", Formatting.countdown(reset.timeIntervalSince(at)), Formatting.clock(reset))
            detail = numbers
            tone = .warning
        } else if let reset = window.resetsAt {
            title = L10n.f("Lasts until the %@ reset", Self.when(reset, now: now))
            subtitle = numbers
            detail = nil
            tone = .fine
        } else {
            title = Formatting.percent(window.usedPercent)
            subtitle = numbers
            detail = nil
            tone = .fine
        }
    }

    /// "5h" / "weekly" in words.
    public static func windowName(_ w: UsageWindow) -> String {
        switch w.kind {
        case .fiveHour: return L10n.t("5-hour")
        case .sevenDay: return L10n.t("weekly")
        case .other: return w.displayLabel
        }
    }

    /// "00:20" today, "Sun 09:00" further out.
    public static func when(_ d: Date, now: Date) -> String {
        if d.timeIntervalSince(now) < 20 * 3600 { return Formatting.clock(d) }
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateFormat = "EEE HH:mm"
        return f.string(from: d)
    }
}

/// How full a session's context is. Claude Code does not say which window a session runs with, so guess:
/// past 200k tokens it must be a 1M window.
public enum ContextGauge {
    public static func fraction(tokens: Int) -> Double {
        let window = tokens > 200_000 ? 1_000_000.0 : 200_000.0
        return min(1, Double(tokens) / window)
    }
}
