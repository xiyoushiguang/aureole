import SwiftUI
import Charts
import AureoleCore

/// What the agents would have cost at public API prices, day by day and month by month, from the token ledger.
/// The subscription is what you actually pay; this is how much work it covered.
struct SpendTab: View {
    @ObservedObject var ledger: LedgerStore
    @State private var range = 30

    var body: some View {
        let days = ledger.daily(since: range)
        Form {
            Section {
                Picker(L10n.t("Show"), selection: $range) {
                    Text(L10n.t("30 days")).tag(30)
                    Text(L10n.t("90 days")).tag(90)
                    Text(L10n.t("1 year")).tag(365)
                }
                .pickerStyle(.segmented)
                if !ledger.ready {
                    Text(L10n.t("Reading the transcripts…")).foregroundStyle(.secondary)
                } else if days.isEmpty {
                    Text(L10n.t("No token use found in Claude Code or Codex transcripts yet.")).foregroundStyle(.secondary)
                } else {
                    Chart(days) {
                        BarMark(x: .value("Day", Self.date($0.day), unit: .day), y: .value("USD", $0.cost))
                            .foregroundStyle(by: .value("Provider", $0.provider.displayName))
                    }
                    .chartForegroundStyleScale(domain: Self.shown(days).map(\.displayName), range: Self.shown(days).map(Theme.accent))
                    .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { Text(Pricing.short(v.as(Double.self) ?? 0)) } } }
                    .frame(height: 170)
                    .environment(\.locale, L10n.locale)
                    let sum = days.reduce(0) { $0 + $1.cost }
                    Text(L10n.f("%@ at API prices over these days, about %@ a day on days with use.", Pricing.short(sum),
                                Pricing.short(sum / Double(Set(days.map(\.day)).count))))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(ledger.providers, id: \.self) { p in
                let months = ledger.ledger.monthly(provider: p).prefix(12)
                if !months.isEmpty {
                    Section(p.displayName) {
                        ForEach(Array(months), id: \.month) { m in
                            HStack {
                                Text(m.month).monospacedDigit()
                                Spacer()
                                Text(Self.tokens(m.total.tally.total)).foregroundStyle(.secondary).monospacedDigit()
                                Text(m.total.tally.isEmpty ? "–" : "≈" + Pricing.short(m.total.cost))
                                    .monospacedDigit().frame(width: 70, alignment: .trailing)
                            }
                        }
                    }
                }
            }
            Section {
                Text(L10n.t("Values at public API prices, read from the transcripts on this Mac. A subscription costs what it costs; this shows how much work it covered. Kept for 400 days, or as far back as the transcripts go (sessions Codex has compressed into .zst archives are not read)."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// The agents with any use in these days, in the usual order, so the legend lists only those.
    static func shown(_ days: [LedgerDay]) -> [ProviderID] {
        let seen = Set(days.map(\.provider))
        return ProviderID.agents.filter { seen.contains($0) }
    }

    static func date(_ day: String) -> Date {
        let p = day.split(separator: "-").compactMap { Int($0) }
        return Calendar.current.date(from: DateComponents(year: p.first, month: p.count > 1 ? p[1] : 1, day: p.count > 2 ? p[2] : 1)) ?? Date()
    }

    static func tokens(_ n: Int) -> String {
        n >= 1_000_000_000 ? String(format: "%.1fB tok", Double(n) / 1e9)
            : n >= 1_000_000 ? String(format: "%.0fM tok", Double(n) / 1e6) : String(format: "%.0fk tok", Double(n) / 1e3)
    }
}
