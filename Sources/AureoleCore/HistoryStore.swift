import Foundation

/// Sample log used for burn-rate prediction and the usage curve. Stored as JSON under Application Support.
///
/// Every reading is kept for `fullDetail`; older ones are thinned to one per `coarseStep` for each window,
/// which is all a week-long curve can show. The file is rewritten whole, so it is saved at most once per
/// `saveInterval` (and by `flush()` when the app quits) rather than after every reading.
public final class HistoryStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.aureole.history")
    private let url: URL
    private var samples: [Sample] = []
    private var saveScheduled = false
    private var dirty = false
    private var lastThinned = Date.distantPast
    public let retention: TimeInterval
    public let saveInterval: TimeInterval
    public static let fullDetail: TimeInterval = 6 * 3600
    public static let coarseStep: TimeInterval = 10 * 60

    public init(url: URL? = nil, retention: TimeInterval = 7 * 86400, saveInterval: TimeInterval = 5 * 60) {
        self.url = url ?? AureolePaths.appSupport.appendingPathComponent("history.json")
        self.retention = retention
        self.saveInterval = saveInterval
        if let data = try? Data(contentsOf: self.url),
           let decoded = try? JSONDecoder.aureole.decode([Sample].self, from: data) {
            samples = Self.thinned(decoded, now: Date())
            lastThinned = Date()
        }
    }

    public func append(_ snapshot: ProviderSnapshot) {
        let new = snapshot.windows.map {
            Sample(t: snapshot.fetchedAt, provider: snapshot.provider, key: $0.key, used: $0.usedPercent, resetsAt: $0.resetsAt)
        }
        queue.sync {
            samples.append(contentsOf: new)
            let now = Date()
            let cutoff = now.addingTimeInterval(-retention)
            if let first = samples.first, first.t < cutoff { samples.removeAll { $0.t < cutoff } }
            if now.timeIntervalSince(lastThinned) >= Self.coarseStep {
                samples = Self.thinned(samples, now: now)
                lastThinned = now
            }
            dirty = true
            scheduleSave()
        }
    }

    public func samples(provider: ProviderID, key: String) -> [Sample] {
        queue.sync { samples.filter { $0.provider == provider && $0.key == key } }
    }

    public var count: Int { queue.sync { samples.count } }

    /// Writes what has not been saved yet, now. For when the app is about to quit.
    public func flush() {
        queue.sync { if dirty { save() } }
    }

    /// Keeps every sample newer than `fullDetail` and, before that, the last one in each `coarseStep` slot of
    /// each window. Order is preserved.
    static func thinned(_ samples: [Sample], now: Date) -> [Sample] {
        let edge = now.addingTimeInterval(-fullDetail)
        guard let first = samples.first, first.t < edge else { return samples }
        var lastInSlot: [String: Int] = [:]
        for (i, s) in samples.enumerated() where s.t < edge {
            let slot = Int((s.t.timeIntervalSince1970 / coarseStep).rounded(.down))
            lastInSlot["\(s.provider.rawValue)|\(s.key)|\(slot)"] = i
        }
        let keep = Set(lastInSlot.values)
        return samples.enumerated().compactMap { i, s in s.t >= edge || keep.contains(i) ? s : nil }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        queue.asyncAfter(deadline: .now() + saveInterval) { [self] in
            saveScheduled = false
            if dirty { save() }
        }
    }

    /// On `queue`.
    private func save() {
        dirty = false
        if let data = try? JSONEncoder.aureole.encode(samples) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}

public extension JSONEncoder {
    static var aureole: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

public extension JSONDecoder {
    static var aureole: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
