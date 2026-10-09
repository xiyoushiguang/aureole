import Foundation

/// A usage provider we know how to read. Add a case here to extend Aureole.
public enum ProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
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
}

public enum ProviderStatus: Equatable, Sendable {
    case idle
    case loading
    case ok
    case signedOut(String)
    case error(String)
    /// The vendor's usage endpoint asked us to slow down; last data stays on screen.
    case rateLimited(until: Date)

    public var message: String? {
        switch self {
        case .signedOut(let m), .error(let m): return m
        default: return nil
        }
    }
}

public enum ProviderError: Error, LocalizedError, Equatable {
    case signedOut(String)
    case http(Int, String)
    case decode(String)
    case transport(String)
    case rateLimited(retryAfter: TimeInterval?)

    public var errorDescription: String? {
        switch self {
        case .rateLimited: return L10n.t("Usage endpoint is rate limiting; backing off")
        case .signedOut(let m): return m
        case .http(let code, let m): return "HTTP \(code): \(m)"
        case .decode(let m): return "Unexpected response: \(m)"
        case .transport(let m): return m
        }
    }
}

public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func fetch() async throws -> ProviderSnapshot
}
