import Foundation

/// Tokens of one model call (or a sum of them), split the way vendors price them.
public struct TokenTally: Codable, Equatable, Sendable {
    /// Input not served from cache.
    public var input = 0
    public var cacheWrite5m = 0
    public var cacheWrite1h = 0
    public var cacheRead = 0
    /// Output, reasoning included.
    public var output = 0

    public init(input: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0, cacheRead: Int = 0, output: Int = 0) {
        self.input = input
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.output = output
    }

    public var total: Int { input + cacheWrite5m + cacheWrite1h + cacheRead + output }
    /// Everything the model read: what decides Haiku 5.5's price tier.
    public var prompt: Int { input + cacheWrite5m + cacheWrite1h + cacheRead }
    public var isEmpty: Bool { total == 0 }

    public static func + (a: TokenTally, b: TokenTally) -> TokenTally {
        TokenTally(input: a.input + b.input, cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m, cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h,
                   cacheRead: a.cacheRead + b.cacheRead, output: a.output + b.output)
    }

    public static func += (a: inout TokenTally, b: TokenTally) { a = a + b }
}

/// USD per million tokens.
public struct ModelPrice: Equatable, Sendable {
    public var input: Double
    public var write5m: Double
    public var write1h: Double
    public var read: Double
    public var output: Double

    public init(input: Double, write5m: Double, write1h: Double, read: Double, output: Double) {
        self.input = input
        self.write5m = write5m
        self.write1h = write1h
        self.read = read
        self.output = output
    }

    /// OpenAI has no separate cache-write price: writes cost what input costs.
    static func openAI(_ input: Double, cached: Double, output: Double) -> ModelPrice {
        ModelPrice(input: input, write5m: input, write1h: input, read: cached, output: output)
    }

    public func cost(_ t: TokenTally) -> Double {
        (Double(t.input) * input + Double(t.cacheWrite5m) * write5m + Double(t.cacheWrite1h) * write1h
            + Double(t.cacheRead) * read + Double(t.output) * output) / 1_000_000
    }
}

/// What a model call would cost at the vendor's public API prices. For a subscription this is an estimate of
/// value, never what was charged. Models without a published price cost nothing here (and say so).
///
/// Sources, read 2026-10-14: platform.claude.com/docs/en/about-claude/pricing and
/// developers.openai.com/api/docs/pricing (standard tier; gpt-6 models and long-context rates added 2026-10-15). Global inference; no fast-mode premium.
/// Gemini, read 2026-10-15 from ai.google.dev/gemini-api/docs/pricing (paid tier, standard, text), including the
/// increases the page announces for later dates.
public enum Pricing {
    /// Claude models, keyed by the part of the id after "claude-". Longest key that prefixes the id wins.
    static let claude: [String: ModelPrice] = [
        "fable-5-1": ModelPrice(input: 10, write5m: 12.5, write1h: 20, read: 0.25, output: 50),
        "mythos-5-1": ModelPrice(input: 10, write5m: 12.5, write1h: 20, read: 0.25, output: 50),
        "fable-5": ModelPrice(input: 10, write5m: 12.5, write1h: 20, read: 1, output: 50),
        "mythos-5": ModelPrice(input: 10, write5m: 12.5, write1h: 20, read: 1, output: 50),
        "opus-5-5": ModelPrice(input: 4, write5m: 5, write1h: 8, read: 0.2, output: 20),
        "opus-5": ModelPrice(input: 5, write5m: 6.25, write1h: 10, read: 0.5, output: 25),
        "opus-4-8": ModelPrice(input: 5, write5m: 6.25, write1h: 10, read: 0.5, output: 25),
        "opus-4-7": ModelPrice(input: 5, write5m: 6.25, write1h: 10, read: 0.5, output: 25),
        "opus-4-6": ModelPrice(input: 5, write5m: 6.25, write1h: 10, read: 0.5, output: 25),
        "opus-4-5": ModelPrice(input: 5, write5m: 6.25, write1h: 10, read: 0.5, output: 25),
        "opus-4-1": ModelPrice(input: 15, write5m: 18.75, write1h: 30, read: 1.5, output: 75),
        "opus-4": ModelPrice(input: 15, write5m: 18.75, write1h: 30, read: 1.5, output: 75),
        "sonnet-5-5": ModelPrice(input: 2, write5m: 2.5, write1h: 4, read: 0.1, output: 10),
        "sonnet-5": ModelPrice(input: 2, write5m: 2.5, write1h: 4, read: 0.2, output: 10),
        "sonnet-4-6": ModelPrice(input: 3, write5m: 3.75, write1h: 6, read: 0.3, output: 15),
        "sonnet-4-5": ModelPrice(input: 3, write5m: 3.75, write1h: 6, read: 0.3, output: 15),
        "sonnet-4": ModelPrice(input: 3, write5m: 3.75, write1h: 6, read: 0.3, output: 15),
        "haiku-5-5": ModelPrice(input: 0.1, write5m: 0.125, write1h: 0.2, read: 0.01, output: 0.5),
        "haiku-4-5": ModelPrice(input: 1, write5m: 1.25, write1h: 2, read: 0.1, output: 5),
        "haiku-3-5": ModelPrice(input: 0.8, write5m: 1, write1h: 1.6, read: 0.08, output: 4),
    ]
    /// Haiku 5.5 above 100k prompt tokens (a request's whole prompt, cache reads and writes included).
    static let haiku55Long = ModelPrice(input: 0.5, write5m: 0.625, write1h: 1, read: 0.05, output: 2.5)
    static let haiku55Threshold = 100_000

    static let openAI: [String: ModelPrice] = [
        "gpt-6-astra": .openAI(10, cached: 1, output: 50),
        "gpt-6.1-sol": .openAI(2, cached: 0.1, output: 10),
        "gpt-6-sol": .openAI(2, cached: 0.2, output: 10),
        "gpt-6-luna": .openAI(0.1, cached: 0.01, output: 0.5),
        "gpt-5.6-sol": .openAI(4, cached: 0.4, output: 20),
        "gpt-5.6-terra": .openAI(2, cached: 0.2, output: 12),
        "gpt-5.6-luna": .openAI(0.2, cached: 0.02, output: 1.2),
        "gpt-5.5-pro": .openAI(30, cached: 30, output: 180),
        "gpt-5.5": .openAI(5, cached: 0.5, output: 30),
        "gpt-5.4-pro": .openAI(30, cached: 30, output: 180),
        "gpt-5.4-mini": .openAI(0.75, cached: 0.075, output: 4.5),
        "gpt-5.4-nano": .openAI(0.2, cached: 0.02, output: 1.25),
        "gpt-5.4": .openAI(2.5, cached: 0.25, output: 15),
        "gpt-5.3-codex": .openAI(1.75, cached: 0.175, output: 14),
        "gpt-5.2-pro": .openAI(21, cached: 21, output: 168),
        "gpt-5.2": .openAI(1.75, cached: 0.175, output: 14),
        "gpt-5.1": .openAI(1.25, cached: 0.125, output: 10),
        "gpt-5-pro": .openAI(15, cached: 15, output: 120),
        "gpt-5-mini": .openAI(0.25, cached: 0.025, output: 2),
        "gpt-5-nano": .openAI(0.05, cached: 0.005, output: 0.4),
        "gpt-5": .openAI(1.25, cached: 0.125, output: 10),
    ]

    /// Gemini text prices: before and from a date when the page announces a change, and above 200k prompt
    /// tokens for the Pro models. Cached input bills at the caching rate.
    struct GeminiPrice {
        var base: ModelPrice
        var long: ModelPrice? = nil
        var later: (from: Date, price: ModelPrice)? = nil
    }
    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }
    static let gemini: [String: GeminiPrice] = [
        "gemini-4-argon": GeminiPrice(base: .openAI(2, cached: 0.1, output: 10),
                                      later: (day(2026, 12, 1), .openAI(4, cached: 0.2, output: 20))),
        "gemini-3.8-flash": GeminiPrice(base: .openAI(0.75, cached: 0.075, output: 3.75),
                                        later: (day(2027, 1, 1), .openAI(1.5, cached: 0.15, output: 7.5))),
        "gemini-3.6-flash": GeminiPrice(base: .openAI(0.75, cached: 0.075, output: 3.75),
                                        later: (day(2027, 1, 1), .openAI(1.5, cached: 0.15, output: 7.5))),
        "gemini-3.5-flash-lite": GeminiPrice(base: .openAI(0.3, cached: 0.03, output: 2.5)),
        "gemini-3.1-flash-lite": GeminiPrice(base: .openAI(0.25, cached: 0.025, output: 1.5)),
        "gemini-3.1-pro-preview": GeminiPrice(base: .openAI(2, cached: 0.2, output: 12), long: .openAI(4, cached: 0.4, output: 18)),
        "gemini-3.1-pro-preview-customtools": GeminiPrice(base: .openAI(2, cached: 0.2, output: 12), long: .openAI(4, cached: 0.4, output: 18)),
        "gemini-3-flash-preview": GeminiPrice(base: .openAI(0.5, cached: 0.05, output: 3)),
        "gemini-2.5-pro": GeminiPrice(base: .openAI(1.25, cached: 0.125, output: 10), long: .openAI(2.5, cached: 0.25, output: 15)),
        "gemini-2.5-flash": GeminiPrice(base: .openAI(0.3, cached: 0.03, output: 2.5)),
        "gemini-2.5-flash-lite": GeminiPrice(base: .openAI(0.1, cached: 0.01, output: 0.4)),
    ]
    static let geminiLongThreshold = 200_000

    /// OpenAI above 272K input tokens (read 2026-10-15, same page).
    static let openAILong: [String: ModelPrice] = [
        "gpt-6-astra": .openAI(20, cached: 2, output: 75),
        "gpt-6.1-sol": .openAI(4, cached: 0.2, output: 15),
        "gpt-6-sol": .openAI(4, cached: 0.4, output: 15),
        "gpt-6-luna": .openAI(0.2, cached: 0.02, output: 0.75),
        "gpt-5.6-sol": .openAI(8, cached: 0.8, output: 30),
        "gpt-5.6-terra": .openAI(4, cached: 0.4, output: 18),
        "gpt-5.6-luna": .openAI(0.4, cached: 0.04, output: 1.8),
        "gpt-5.5": .openAI(10, cached: 1, output: 45),
        "gpt-5.4": .openAI(5, cached: 0.5, output: 22.5),
        "gpt-5.4-pro": .openAI(60, cached: 60, output: 270),
        "gpt-5.5-pro": .openAI(60, cached: 60, output: 270),
    ]
    static let openAILongThreshold = 272_000

    /// The price of one call to `model`; nil for a model with no published price.
    public static func price(model: String, tally: TokenTally = TokenTally(), at: Date = Date()) -> ModelPrice? {
        let id = model.lowercased()
        if id.hasPrefix("gemini-") {
            // Exact names, as for OpenAI: a "-lite" or "-image" variant has its own line.
            guard let g = gemini[id] else { return nil }
            if let long = g.long, tally.prompt > geminiLongThreshold { return long }
            if let later = g.later, at >= later.from { return later.price }
            return g.base
        }
        if id.hasPrefix("claude-") {
            let rest = String(id.dropFirst("claude-".count))
            guard let key = longestPrefix(of: rest, in: claude.keys) else { return nil }
            if key == "haiku-5-5", tally.prompt > haiku55Threshold { return haiku55Long }
            return claude[key]
        }
        // Exact names only for OpenAI: "gpt-5.5" must not price "gpt-5.5-cyber", which is not on the list.
        // A dated snapshot ("gpt-5.4-2026-03-05") prices like its model.
        var key: String? = openAI[id] != nil ? id : nil
        if key == nil, let k = longestPrefix(of: id, in: openAI.keys), id.dropFirst(k.count).first == "-",
           id.dropFirst(k.count + 1).first?.isNumber == true { key = k }
        guard let key else { return nil }
        if tally.prompt > openAILongThreshold, let long = openAILong[key] { return long }
        return openAI[key]
    }

    public static func cost(model: String, tally: TokenTally, at: Date = Date()) -> Double? {
        price(model: model, tally: tally, at: at)?.cost(tally)
    }

    /// The key must match a whole segment: "opus-5" prefixes "opus-5-20260101" but not "opus-55".
    static func longestPrefix(of id: String, in keys: Dictionary<String, ModelPrice>.Keys) -> String? {
        keys.filter { k in
            guard id.hasPrefix(k) else { return false }
            let next = id.dropFirst(k.count).first
            return next == nil || next == "-" || next == "@" || next == "["
        }.max { $0.count < $1.count }
    }

    /// "$0.42", "$3.2", "$68" — short, and always marked as an estimate by the caller.
    public static func short(_ usd: Double) -> String {
        if usd < 0.01 { return "$0" }
        if usd < 1 { return String(format: "$%.2f", usd) }
        if usd < 10 { return String(format: "$%.1f", usd) }
        return "$\(Int(usd.rounded()))"
    }
}
