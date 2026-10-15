import Foundation
import AureoleCore

/// Keeps the token ledger current: reads what the agents appended to their transcripts every 20 seconds, off the
/// main thread, and saves where it stopped so a relaunch only reads what is new.
@MainActor
final class LedgerStore: ObservableObject {
    @Published private(set) var ledger = TokenLedger() { didSet { sessionTotals = ledger.totals() } }
    /// Per session, everything in the ledger; recomputed only when the ledger changes.
    private(set) var sessionTotals: [String: TokenLedger.Total] = [:]
    /// The first read after launch is done (on a first run that can take a few seconds).
    @Published private(set) var ready = false

    private let queue = DispatchQueue(label: "app.aureole.ledger", qos: .utility)
    private var timer: Timer?
    private var scanning = false
    private let url = AureolePaths.appSupport.appendingPathComponent("ledger.json")
    /// Demo data, never scanned or saved.
    private var frozen = false

    func start() {
        guard !frozen else { return }
        let url = url
        queue.async { [weak self] in
            var ledger = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder.aureole.decode(TokenLedger.self, from: $0) } ?? TokenLedger()
            // A ledger from before day totals: read everything once more, this time back as far as the files go.
            // A first run reads back as far as the files go, as does a ledger saved by an older version; the day
            // totals it already had are kept where the files are gone.
            let backfill = ledger.version < TokenLedger.currentVersion || (ledger.cursors.isEmpty && ledger.days.isEmpty)
            let started = Date()
            var changed: Bool
            if backfill {
                let old = ledger
                ledger = TokenLedger()
                LedgerScanner.scan(&ledger, sources: LedgerScanner.sources(everything: true))
                ledger.keepHistory(from: old)
                changed = true
            } else {
                changed = LedgerScanner.scan(&ledger, sources: LedgerScanner.sources(known: Set(ledger.cursors.keys)))
            }
            if changed { Self.save(ledger, to: url) }
            let took = Date().timeIntervalSince(started)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.ledger = ledger
                    self.ready = true
                    AureoleLog.shared.log("ledger: \(ledger.buckets.count) buckets from \(ledger.cursors.count) transcripts, read in \(String(format: "%.1f", took)) s")
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
    }

    /// Fixed numbers for `--demo` and snapshots.
    func freeze(_ ledger: TokenLedger) {
        frozen = true
        timer?.invalidate()
        self.ledger = ledger
        ready = true
    }

    private func rescan() {
        guard ready, !scanning, !frozen else { return }
        scanning = true
        var copy = ledger
        let url = url
        queue.async { [weak self] in
            let changed = LedgerScanner.scan(&copy, sources: LedgerScanner.sources(known: Set(copy.cursors.keys)))
            if changed { Self.save(copy, to: url) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scanning = false
                    if changed { self.ledger = copy }
                }
            }
        }
    }

    nonisolated private static func save(_ ledger: TokenLedger, to url: URL) {
        guard let data = try? JSONEncoder.aureole.encode(ledger) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - Queries for the panel

    func total(session id: String) -> TokenLedger.Total? {
        let t = sessionTotals[id]
        return t?.tally.isEmpty == false ? t : nil
    }

    /// API-price value of everything spent with a provider since `from`.
    func cost(_ provider: ProviderID, since from: Date) -> Double? {
        let t = ledger.total(provider: provider, from: from)
        return t.tally.isEmpty ? nil : t.cost
    }

    /// Providers with any day totals, in the usual order.
    var providers: [ProviderID] {
        let seen = Set(ledger.days.values.map(\.provider))
        return ProviderID.agents.filter { seen.contains($0) }
    }

    /// Day totals for the spend history, oldest first.
    func daily(since days: Int) -> [LedgerDay] {
        ledger.daily(from: TokenLedger.dayKey(Date().addingTimeInterval(-Double(days - 1) * 86400)))
    }

    /// A name for a session that may no longer have a lane: its title, else its folder.
    func name(of id: String) -> String? {
        ledger.titles[id] ?? ledger.folders[id].map { ($0 as NSString).lastPathComponent }
    }
}
