import Foundation

/// Append-only sample log used for burn-rate prediction. Stored as JSON under Application Support.
public final class HistoryStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.aureole.history")
    private let url: URL
    private var samples: [Sample] = []
    private var saveScheduled = false
    public let retention: TimeInterval

    public init(url: URL? = nil, retention: TimeInterval = 7 * 86400) {
        self.url = url ?? AureolePaths.appSupport.appendingPathComponent("history.json")
        self.retention = retention
        if let data = try? Data(contentsOf: self.url),
           let decoded = try? JSONDecoder.aureole.decode([Sample].self, from: data) {
            samples = decoded
        }
    }

    public func append(_ snapshot: ProviderSnapshot) {
        let new = snapshot.windows.map {
            Sample(t: snapshot.fetchedAt, provider: snapshot.provider, key: $0.key, used: $0.usedPercent, resetsAt: $0.resetsAt)
        }
        queue.sync {
            samples.append(contentsOf: new)
            let cutoff = Date().addingTimeInterval(-retention)
            samples.removeAll { $0.t < cutoff }
            scheduleSave()
        }
    }

    public func samples(provider: ProviderID, key: String) -> [Sample] {
        queue.sync { samples.filter { $0.provider == provider && $0.key == key } }
    }

    public var count: Int { queue.sync { samples.count } }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        queue.asyncAfter(deadline: .now() + 3) { [self] in
            saveScheduled = false
            if let data = try? JSONEncoder.aureole.encode(samples) {
                try? data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
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
