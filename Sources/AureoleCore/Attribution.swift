import Foundation

/// Who used the quota: each rise of the usage curve is split among the sessions that spent tokens in that
/// stretch, in proportion to what those tokens cost. The vendor never says which session burned what, so this is
/// an estimate, and a rise with no tokens behind it (another device, the web app) stays "other".
public struct QuotaAttribution: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        public var t: Date
        /// Used percent at this point, as the curve says.
        public var used: Double
        /// Percentage points credited to each session from the first point up to here.
        public var bySession: [String: Double]
    }

    /// Usage at the first point: spent before the stretch we can split.
    public var base: Double
    public var points: [Point]
    /// Sessions by total share, largest first.
    public var order: [String]
    /// Percentage points per session over the whole stretch.
    public var shares: [String: Double]

    public static let other = "~other"

    /// - Parameters:
    ///   - curve: (time, used %) oldest first, ending at "now".
    ///   - weights: per minute (since 1970), per session, how much was spent.
    public static func split(curve: [(t: Date, used: Double)], weights: [Int: [String: Double]]) -> QuotaAttribution? {
        guard let first = curve.first, curve.count >= 2 else { return nil }
        let minutes = weights.keys.sorted()
        var running: [String: Double] = [:]
        var points = [Point(t: first.t, used: first.used, bySession: [:])]
        // The curve is in time order, so one pass over the minutes does; `j` is the first minute not yet passed.
        var j = 0
        for i in 1..<curve.count {
            let rise = max(0, curve[i].used - curve[i - 1].used)
            // Tokens spent after the previous reading and up to this one; a reading can lag its calls by a little,
            // so the stretch reaches back a few minutes.
            let a = Int(curve[i - 1].t.timeIntervalSince1970 / 60) - 3, z = Int(curve[i].t.timeIntervalSince1970 / 60)
            while j < minutes.count, minutes[j] <= a { j += 1 }
            var k = j
            var spent: [String: Double] = [:]
            while k < minutes.count, minutes[k] <= z {
                if rise > 0 { for (s, w) in weights[minutes[k]] ?? [:] { spent[s, default: 0] += w } }
                k += 1
            }
            if rise > 0 {
                let sum = spent.values.reduce(0, +)
                if sum > 0 {
                    for (s, w) in spent { running[s, default: 0] += rise * w / sum }
                } else {
                    running[other, default: 0] += rise
                }
            }
            points.append(Point(t: curve[i].t, used: curve[i].used, bySession: running))
        }
        guard !running.isEmpty else { return nil }
        // A reading that fell back (the vendor revised it) leaves less to share out than was credited; the shares
        // shrink in proportion, so they add up to what the curve shows.
        let room = max(0, (curve.last?.used ?? 0) - first.used), credited = running.values.reduce(0, +)
        if credited > room, credited > 0 { running = running.mapValues { $0 * room / credited } }
        let order = running.filter { $0.key != other }.sorted { $0.value > $1.value }.map(\.key)
        return QuotaAttribution(base: first.used, points: points, order: order, shares: running)
    }

    /// The sessions drawn in their own colour (the largest few); the rest are folded into "other".
    public func bands(max: Int = 4) -> [String] {
        Array(order.prefix(max)) + (shares.keys.contains(Self.other) || order.count > max ? [Self.other] : [])
    }

    /// Stacked from the base up, in `bands` order: the lower and upper used-% of each band at point `i`.
    /// A falling reading (the vendor revised it down) squeezes every band in proportion, so the stack never
    /// rises above the curve.
    public func stack(at i: Int, bands: [String]) -> [(key: String, lower: Double, upper: Double)] {
        let p = points[i]
        let named = Set(bands).subtracting([Self.other])
        var parts: [(String, Double)] = bands.map { key in
            key == Self.other ? (key, p.bySession.filter { !named.contains($0.key) }.values.reduce(0, +)) : (key, p.bySession[key] ?? 0)
        }
        let credited = parts.map(\.1).reduce(0, +)
        let room = max(0, p.used - base)
        if credited > room, credited > 0 { parts = parts.map { ($0.0, $0.1 * room / credited) } }
        var y = base
        return parts.map { key, v in
            defer { y += v }
            return (key, y, y + v)
        }
    }
}
