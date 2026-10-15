import SwiftUI
import AureoleCore

/// What one session spent (from the token ledger) and its share of the quota on the horizon.
struct LaneSpend {
    var total: TokenLedger.Total?
    /// Percentage points of the horizon's window credited to this session.
    var share: Double?
    /// Its band colour, when it is among the largest few.
    var color: Color?

    init?(lane: HorizonLane, scene: HorizonScene, total: TokenLedger.Total?) {
        self.total = total
        share = scene.attribution?.shares[lane.id]
        color = HorizonColor.band(lane.id, in: scene.attribution)
        if total == nil && share == nil { return nil }
    }
}

enum SpendText {
    /// "≈$3.2 · 18% of quota", the short form on a lane.
    static func short(_ spend: LaneSpend) -> String? {
        var parts: [String] = []
        if let c = spend.total?.cost, c >= 0.01 { parts.append("≈" + Pricing.short(c)) }
        if let s = spend.share, s >= 0.5 { parts.append(L10n.f("%d%% of quota", Int(s.rounded()))) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "52M tokens · ≈$24.7 · cache 99%", for the details card.
    static func tokens(_ t: TokenLedger.Total) -> String {
        var parts = [L10n.f("%@ tokens", TranscriptReader.short(t.tally.total))]
        if t.cost >= 0.01 { parts.append("≈" + Pricing.short(t.cost)) }
        if let hit = t.cacheHitRate { parts.append(L10n.f("cache %d%%", Int((hit * 100).rounded()))) }
        return parts.joined(separator: " · ")
    }
}

/// Under the headline: whose sessions used this window, in the colours of their bands.
struct AttributionLegend: View {
    let attribution: QuotaAttribution
    let name: (String) -> String

    var body: some View {
        let keys = attribution.bands()
        HStack(spacing: 10) {
            Text(L10n.t("Used by")).foregroundStyle(HorizonColor.label)
            ForEach(keys, id: \.self) { key in
                let pct = Int((share(key)).rounded())
                if pct >= 1, let color = HorizonColor.band(key, in: attribution) {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
                        Text(key == QuotaAttribution.other ? L10n.t("other") : SessionText.short(name(key)))
                            .foregroundStyle(.white.opacity(0.82))
                        Text("\(pct)%").foregroundStyle(HorizonColor.label)
                    }
                }
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 3)
        // The "now" line runs down through here; a backing keeps the words whole.
        .background(Capsule().fill(HorizonColor.ground.opacity(0.85)))
        .help(L10n.t("Each rise of the curve is split among the sessions that spent tokens at that moment, by what those tokens cost at API prices. An estimate: vendors do not say which session used what. Rises with no tokens behind them (another Mac, the web app) count as other."))
    }

    /// A named session's share, or for "other" everything not drawn on its own.
    private func share(_ key: String) -> Double {
        guard key == QuotaAttribution.other else { return attribution.shares[key] ?? 0 }
        let named = Set(attribution.bands()).subtracting([QuotaAttribution.other])
        return attribution.shares.filter { !named.contains($0.key) }.values.reduce(0, +)
    }
}
