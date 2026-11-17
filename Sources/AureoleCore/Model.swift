import Foundation

/// A usage provider we know how to read. Add a case here to extend Aureole.
public enum ProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex
    /// Agents with sessions and tokens but no quota Aureole can read.
    case gemini, opencode
    /// A lane a script reports through `aureole-hook --lane` (a nightly job, a long build). Has no quota.
    case task

    /// The providers with a quota to read. `.task` is only ever a lane.
    public static var allCases: [ProviderID] { [.claude, .codex] }
    /// Every agent that can have sessions and a token ledger, quota or not.
    public static var agents: [ProviderID] { [.claude, .codex, .gemini, .opencode] }

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .opencode: return "opencode"
        case .task: return L10n.t("Task")
        }
    }
}

public enum WindowKind: String, Codable, Sendable {
    case fiveHour, sevenDay, other
}

/// One rate-limit window (e.g. the rolling 5-hour session or the weekly cap).
public struct UsageWindow: Codable, Equatable, Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let label: String
    public let kind: WindowKind
    /// 0...100, may exceed 100 when a provider reports overage.
    public let usedPercent: Double
    public let resetsAt: Date?
    /// Window length in seconds, when known.
    public let duration: TimeInterval?
    /// Money windows (pay-as-you-go spend): dollars used and the cap, when the provider says.
    public var usedUSD: Double?
    public var limitUSD: Double?

    public init(key: String, label: String, kind: WindowKind, usedPercent: Double, resetsAt: Date?, duration: TimeInterval?,
                usedUSD: Double? = nil, limitUSD: Double? = nil) {
        self.key = key
        self.label = label
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.duration = duration
        self.usedUSD = usedUSD
        self.limitUSD = limitUSD
    }

    /// Spend beyond the plan (Claude's extra usage, or a spend limit set by an admin or gateway).
    public var isSpend: Bool { key == "extra_usage" || key == "spend_limit" }

    public var remainingPercent: Double { max(0, 100 - usedPercent) }

    /// Localised label ("5h" / "Week" / "Fable wk").
    public var displayLabel: String {
        switch kind {
        case .fiveHour: return L10n.t("5h")
        case .sevenDay: return L10n.t("Week")
        case .other:
            if label.hasSuffix(" wk") { return L10n.f("%@ wk", String(label.dropLast(3))) }
            if label.hasSuffix(" 5h") { return L10n.f("%@ 5h", String(label.dropLast(3))) }
            return L10n.t(label)
        }
    }

    /// How far into the window we are (0 = just reset, 1 = about to reset).
    public func elapsedFraction(now: Date = Date()) -> Double? {
        guard let resetsAt, let duration, duration > 0 else { return nil }
        let remaining = max(0, resetsAt.timeIntervalSince(now))
        return min(1, max(0, 1 - remaining / duration))
    }

    /// Positive when usage is ahead of the clock (burning faster than the window allows).
    public func paceDelta(now: Date = Date()) -> Double? {
        elapsedFraction(now: now).map { usedPercent - $0 * 100 }
    }

    /// The window as it stands once its reset time has passed and nothing newer has been read: empty.
    /// A 5-hour window only starts again with the next message, so it has no reset time until then; a
    /// fixed-length window moves on to its next reset. Money windows are left alone: what was spent stays spent
    /// until the vendor says otherwise.
    public func rolledOver(now: Date = Date()) -> UsageWindow {
        guard let reset = resetsAt, reset <= now, !isSpend else { return self }
        var next: Date?
        if kind != .fiveHour, let d = duration, d > 0 {
            let cycles = (now.timeIntervalSince(reset) / d).rounded(.down) + 1
            next = reset.addingTimeInterval(cycles * d)
        }
        return UsageWindow(key: key, label: label, kind: kind, usedPercent: 0, resetsAt: next, duration: duration)
    }
}

public struct ProviderSnapshot: Codable, Equatable, Sendable {
    public let provider: ProviderID
    public let windows: [UsageWindow]
    public let fetchedAt: Date
    public let planLabel: String?

    public init(provider: ProviderID, windows: [UsageWindow], fetchedAt: Date, planLabel: String?) {
        self.provider = provider
        self.windows = windows
        self.fetchedAt = fetchedAt
        self.planLabel = planLabel
    }

    public var session: UsageWindow? { windows.first { $0.kind == .fiveHour } }
    public var weekly: UsageWindow? { windows.first { $0.kind == .sevenDay } }
    public var extras: [UsageWindow] { windows.filter { $0.kind == .other } }
    /// The window that best represents "how much is left right now": the session window,
    /// or the weekly one on plans that only meter weekly (e.g. some Codex tiers).
    public var primary: UsageWindow? { session ?? weekly ?? windows.first }

    /// The same reading with every window that has reset since it was taken shown empty (see
    /// `UsageWindow.rolledOver`). A reset time the vendor reported as already past is left as reported: the
    /// number that came with it is newer than that reset. `fetchedAt` stays: nothing new has been read.
    public func rolledOver(now: Date = Date()) -> ProviderSnapshot {
        func due(_ w: UsageWindow) -> Bool {
            guard let reset = w.resetsAt, !w.isSpend else { return false }
            return reset > fetchedAt && reset <= now
        }
        guard windows.contains(where: due) else { return self }
        return ProviderSnapshot(provider: provider, windows: windows.map { due($0) ? $0.rolledOver(now: now) : $0 },
                                fetchedAt: fetchedAt, planLabel: planLabel)
    }

    /// The earliest reset among the windows that is still ahead of this reading.
    public var nextReset: Date? {
        windows.compactMap(\.resetsAt).filter { $0 > fetchedAt }.min()
    }
}

public enum ProviderStatus: Equatable, Sendable {
    case idle
    case loading
    case ok
    case signedOut(String)
    case error(String)
    /// The vendor's usage endpoint asked us to slow down; last data stays on screen.
    case rateLimited(until: Date)
    /// The stored token has run out. The agent's own CLI renews it the next time it runs; until then there is
    /// nothing to ask with. Not a fault, and never announced.
    case expired(String)

    /// What went wrong, when something did.
    public var message: String? {
        switch self {
        case .signedOut(let m), .error(let m): return m
        default: return nil
        }
    }

    /// Something worth saying that is not a fault.
    public var note: String? {
        if case .expired(let m) = self { return m }
        return nil
    }

    /// True while the last attempt to read did not bring numbers back.
    public var isFailing: Bool {
        switch self {
        case .signedOut, .error, .rateLimited, .expired: return true
        case .idle, .loading, .ok: return false
        }
    }
}

public enum ProviderError: Error, LocalizedError, Equatable {
    case signedOut(String)
    case http(Int, String)
    case decode(String)
    case transport(String)
    /// The network or a proxy failed; the vendor and the sign-in are fine as far as we know.
    case network(String)
    case rateLimited(retryAfter: TimeInterval?)
    /// The stored token is past its expiry time, so asking would only be refused.
    case expired(String)

    public var errorDescription: String? {
        switch self {
        case .rateLimited: return L10n.t("Usage endpoint is rate limiting; backing off")
        case .signedOut(let m), .expired(let m): return m
        case .http(let code, let m): return "HTTP \(code): \(m)"
        case .decode(let m): return "Unexpected response: \(m)"
        case .transport(let m): return m
        case .network(let m): return L10n.f("Network or proxy problem (%@). Refreshes by itself once the connection is back.", m)
        }
    }
}

public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func fetch() async throws -> ProviderSnapshot
}
