import Foundation

/// Token use by session, model and minute, read from the transcripts Claude Code and Codex already keep.
/// Nothing is asked of any vendor; the files are only read, from where the last read stopped.
public struct LedgerBucket: Codable, Equatable, Sendable {
    public var provider: ProviderID
    public var session: String
    public var model: String
    /// Minutes since 1970.
    public var minute: Int
    public var tally: TokenTally
    /// At public API prices; calls to models without a published price add nothing.
    public var cost: Double
    /// Tokens of calls that had no price.
    public var unpriced: Int

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(minute) * 60) }
}

/// A provider's use on one calendar day, kept long after the minute buckets are pruned.
public struct LedgerDay: Codable, Equatable, Sendable {
    public var provider: ProviderID
    /// yyyy-MM-dd in the Mac's time zone at the time of the call.
    public var day: String
    public var tally: TokenTally
    public var cost: Double
    public var unpriced: Int
    public init(provider: ProviderID, day: String, tally: TokenTally, cost: Double, unpriced: Int) {
        self.provider = provider; self.day = day; self.tally = tally; self.cost = cost; self.unpriced = unpriced
    }
}

/// One model call, as read from a transcript line.
public struct LedgerCall: Equatable, Sendable {
    public var at: Date
    public var model: String
    public var tally: TokenTally
    public init(at: Date, model: String, tally: TokenTally) { self.at = at; self.model = model; self.tally = tally }
}

/// What we know about a transcript file between reads.
public struct LedgerCursor: Codable, Equatable, Sendable {
    public var offset: UInt64 = 0
    /// Claude: ids of the last messages counted (one message is written as several lines with the same usage).
    public var recentIds: [String] = []
    /// Codex: running totals at the last token_count, and the model of the current turn.
    public var codexTotal: TokenTally?
    public var codexModel: String?
    public init() {}
}

public enum TranscriptLines {
    /// A Claude Code transcript line with an assistant message's usage. Returns the message id with the call
    /// so the caller can skip the repeats Claude Code writes for each content block.
    public static func claude(_ line: Data) -> (id: String?, call: LedgerCall)? {
        guard line.range(of: Data("\"usage\"".utf8)) != nil, line.range(of: Data("\"assistant\"".utf8)) != nil,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String, model != "<synthetic>",
              let at = DateParsing.parse(obj["timestamp"]) else { return nil }
        func n(_ d: [String: Any]?, _ k: String) -> Int { (d?[k] as? NSNumber)?.intValue ?? 0 }
        let writes = n(usage, "cache_creation_input_tokens")
        let split = usage["cache_creation"] as? [String: Any]
        let w1h = split == nil ? 0 : n(split, "ephemeral_1h_input_tokens")
        let tally = TokenTally(input: n(usage, "input_tokens"), cacheWrite5m: max(0, writes - w1h), cacheWrite1h: w1h,
                               cacheRead: n(usage, "cache_read_input_tokens"), output: n(usage, "output_tokens"))
        guard !tally.isEmpty else { return nil }
        return (message["id"] as? String, LedgerCall(at: at, model: model, tally: tally))
    }

    /// The ai-title line of a Claude Code transcript.
    public static func claudeTitle(_ line: Data) -> String? {
        guard line.range(of: Data("\"ai-title\"".utf8)) != nil,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "ai-title", let t = obj["aiTitle"] as? String, !t.isEmpty else { return nil }
        return t
    }

    /// Folds one Codex rollout line into the cursor; returns a call for each token_count that moved the totals.
    /// OpenAI counts cached input inside input, so it is taken out here.
    public static func codex(_ line: Data, cursor: inout LedgerCursor) -> LedgerCall? {
        let isTurn = line.range(of: Data("\"turn_context\"".utf8)) != nil
        let isCount = line.range(of: Data("\"token_count\"".utf8)) != nil
        guard isTurn || isCount, let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = obj["payload"] as? [String: Any] else { return nil }
        if obj["type"] as? String == "turn_context" {
            if let m = payload["model"] as? String { cursor.codexModel = m }
            return nil
        }
        guard payload["type"] as? String == "token_count", let info = payload["info"] as? [String: Any],
              let total = info["total_token_usage"] as? [String: Any], let at = DateParsing.parse(obj["timestamp"]) else { return nil }
        func n(_ k: String) -> Int { (total[k] as? NSNumber)?.intValue ?? 0 }
        let cached = n("cached_input_tokens")
        let now = TokenTally(input: max(0, n("input_tokens") - cached), cacheWrite5m: n("cache_write_input_tokens"),
                             cacheRead: cached, output: n("output_tokens"))
        let before = cursor.codexTotal ?? TokenTally()
        cursor.codexTotal = now
        // Totals only grow within a session; if they shrank the file was rewritten, so count from zero.
        let shrank = now.total < before.total
        let delta = shrank ? now : TokenTally(input: max(0, now.input - before.input), cacheWrite5m: max(0, now.cacheWrite5m - before.cacheWrite5m),
                                              cacheRead: max(0, now.cacheRead - before.cacheRead), output: max(0, now.output - before.output))
        guard !delta.isEmpty else { return nil }
        return LedgerCall(at: at, model: cursor.codexModel ?? "codex", tally: delta)
    }
}

/// The ledger itself: buckets plus where each file was read up to. Pure data, so it can be tested and saved.
public struct TokenLedger: Codable, Equatable, Sendable {
    public var buckets: [String: LedgerBucket] = [:]
    public var cursors: [String: LedgerCursor] = [:]
    /// Conversation titles found while reading (Claude's ai-title), by session.
    public var titles: [String: String] = [:]
    /// Each session's folder, for a name when it has no title.
    public var folders: [String: String] = [:]
    /// Per provider and day, by "provider|yyyy-MM-dd".
    public var days: [String: LedgerDay] = [:]
    /// 0 for a ledger saved before day totals existed; such a ledger is read again from scratch once.
    public var version = 0
    public static let currentVersion = 1   // bump to re-read every transcript (a new day field, a price fix)
    public static let retention: TimeInterval = 8 * 86400
    /// How long day totals are kept.
    public static let history: TimeInterval = 400 * 86400

    public init() { version = Self.currentVersion }

    enum CodingKeys: String, CodingKey { case buckets, cursors, titles, folders, days, version }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        buckets = try c.decodeIfPresent([String: LedgerBucket].self, forKey: .buckets) ?? [:]
        cursors = try c.decodeIfPresent([String: LedgerCursor].self, forKey: .cursors) ?? [:]
        titles = try c.decodeIfPresent([String: String].self, forKey: .titles) ?? [:]
        folders = try c.decodeIfPresent([String: String].self, forKey: .folders) ?? [:]
        days = try c.decodeIfPresent([String: LedgerDay].self, forKey: .days) ?? [:]
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
    }

    public static func dayKey(_ date: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public mutating func add(_ call: LedgerCall, provider: ProviderID, session: String) {
        let minute = Int(call.at.timeIntervalSince1970 / 60)
        let key = "\(provider.rawValue)|\(session)|\(call.model)|\(minute)"
        var b = buckets[key] ?? LedgerBucket(provider: provider, session: session, model: call.model, minute: minute,
                                              tally: TokenTally(), cost: 0, unpriced: 0)
        b.tally += call.tally
        let cost = Pricing.cost(model: call.model, tally: call.tally, at: call.at)
        if let cost { b.cost += cost } else { b.unpriced += call.tally.total }
        buckets[key] = b
        let day = Self.dayKey(call.at)
        var d = days["\(provider.rawValue)|\(day)"] ?? LedgerDay(provider: provider, day: day, tally: TokenTally(), cost: 0, unpriced: 0)
        d.tally += call.tally
        if let cost { d.cost += cost } else { d.unpriced += call.tally.total }
        days["\(provider.rawValue)|\(day)"] = d
    }

    public mutating func prune(now: Date) {
        let cutoff = Int(now.addingTimeInterval(-Self.retention).timeIntervalSince1970 / 60)
        buckets = buckets.filter { $0.value.minute >= cutoff }
        let live = Set(buckets.values.map(\.session))
        titles = titles.filter { live.contains($0.key) }
        folders = folders.filter { live.contains($0.key) }
        let oldest = Self.dayKey(now.addingTimeInterval(-Self.history))
        days = days.filter { $0.value.day >= oldest }
    }

    /// Day totals for a provider (all providers when nil), oldest first, one entry per day that had any use.
    public func daily(provider: ProviderID? = nil, from: String? = nil) -> [LedgerDay] {
        days.values.filter { (provider == nil || $0.provider == provider) && (from == nil || $0.day >= from!) }
            .sorted { ($0.day, $0.provider.rawValue) < ($1.day, $1.provider.rawValue) }
    }

    /// Month totals ("yyyy-MM") for a provider, newest first.
    public func monthly(provider: ProviderID) -> [(month: String, total: Total)] {
        var out: [String: Total] = [:]
        for d in days.values where d.provider == provider {
            var t = out[String(d.day.prefix(7)), default: Total()]
            t.tally += d.tally; t.cost += d.cost; t.unpriced += d.unpriced
            out[String(d.day.prefix(7))] = t
        }
        return out.sorted { $0.key > $1.key }.map { ($0.key, $0.value) }
    }

    // MARK: Queries

    public struct Total: Equatable, Sendable {
        public var tally = TokenTally()
        public var cost = 0.0
        public var unpriced = 0
        /// Cache reads over everything read, the share that came cheap.
        public var cacheHitRate: Double? {
            tally.prompt > 0 ? Double(tally.cacheRead) / Double(tally.prompt) : nil
        }
        mutating func add(_ b: LedgerBucket) { tally += b.tally; cost += b.cost; unpriced += b.unpriced }
    }

    public func totals(bySessionOf provider: ProviderID? = nil, from: Date? = nil) -> [String: Total] {
        let start = from.map { Int($0.timeIntervalSince1970 / 60) } ?? .min
        var out: [String: Total] = [:]
        for b in buckets.values where (provider == nil || b.provider == provider) && b.minute >= start {
            out[b.session, default: Total()].add(b)
        }
        return out
    }

    public func total(provider: ProviderID, from: Date, to: Date = .distantFuture) -> Total {
        let a = Int(from.timeIntervalSince1970 / 60), z = to == .distantFuture ? Int.max : Int(to.timeIntervalSince1970 / 60)
        var t = Total()
        for b in buckets.values where b.provider == provider && b.minute >= a && b.minute <= z { t.add(b) }
        return t
    }

    /// Per minute and session, what counts toward a provider's quota: the API-price cost, or for a model
    /// without a price its tokens at a nominal rate, so it still takes a share.
    public func weights(provider: ProviderID, from: Date) -> [Int: [String: Double]] {
        let start = Int(from.timeIntervalSince1970 / 60)
        var out: [Int: [String: Double]] = [:]
        for b in buckets.values where b.provider == provider && b.minute >= start {
            out[b.minute, default: [:]][b.session, default: 0] += b.cost + Double(b.unpriced) * 2 / 1_000_000
        }
        return out
    }
}

/// Reads new lines from transcripts into a ledger. File access lives here; parsing lives in `TranscriptLines`.
public enum LedgerScanner {
    public struct Source: Equatable, Sendable {
        public var url: URL
        public var provider: ProviderID
        public var session: String
    }

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Claude transcripts (and their sub-agents', counted to the parent) and Codex rollouts touched within the retention.
    /// With `everything`, all transcripts still on disk within the day-total history (the one-time backfill).
    public static func sources(now: Date = Date(), claudeRoot: URL? = nil, codexRoot: URL? = nil, geminiRoot: URL? = nil,
                               opencodeRoot: URL? = nil, everything: Bool = false) -> [Source] {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-(everything ? TokenLedger.history : TokenLedger.retention))
        func recent(_ url: URL) -> Bool {
            ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) >= cutoff
        }
        func list(_ dir: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])) ?? []
        }
        var out: [Source] = []
        let projects = claudeRoot ?? home.appendingPathComponent(".claude/projects")
        for project in list(projects) {
            for item in list(project) {
                if item.pathExtension == "jsonl" {
                    if recent(item) { out.append(Source(url: item, provider: .claude, session: item.deletingPathExtension().lastPathComponent)) }
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    for sub in list(item.appendingPathComponent("subagents")) where sub.pathExtension == "jsonl" && recent(sub) {
                        out.append(Source(url: sub, provider: .claude, session: item.lastPathComponent))
                    }
                }
            }
        }
        // ~/.codex/sessions/YYYY/MM/DD/rollout-…-<thread id>.jsonl; only the days inside the retention.
        let sessions = codexRoot ?? home.appendingPathComponent(".codex/sessions")
        let cal = Calendar(identifier: .gregorian)
        for back in 0...Int((everything ? TokenLedger.history : TokenLedger.retention) / 86400) {
            let day = cal.dateComponents([.year, .month, .day], from: now.addingTimeInterval(-Double(back) * 86400))
            let dir = sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0))
            for file in list(dir) where file.pathExtension == "jsonl" && recent(file) {
                out.append(Source(url: file, provider: .codex, session: codexThread(file)))
            }
        }
        // Gemini CLI: ~/.gemini/tmp/<project>/chats/session-….jsonl, sub-agents in chats/<parent session>/….jsonl.
        // The session id is on the file's first line.
        for project in list(geminiRoot ?? GeminiHooks.chatsRoot) {
            for item in list(project.appendingPathComponent("chats")) {
                if item.pathExtension == "jsonl" {
                    if recent(item), let id = firstLine(item).flatMap(TranscriptLines.geminiSession) {
                        out.append(Source(url: item, provider: .gemini, session: id))
                    }
                } else {
                    for sub in list(item) where sub.pathExtension == "jsonl" && recent(sub) {
                        out.append(Source(url: sub, provider: .gemini, session: item.lastPathComponent))
                    }
                }
            }
        }
        // opencode, through Aureole's own plugin: one usage log per session.
        for file in list(opencodeRoot ?? OpencodePlugin.usageDir) where file.pathExtension == "jsonl" && recent(file) {
            out.append(Source(url: file, provider: .opencode, session: file.deletingPathExtension().lastPathComponent))
        }
        return out
    }

    static func firstLine(_ url: URL) -> Data? {
        guard let h = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 64 << 10), let nl = head.firstIndex(of: 0x0A) else { return nil }
        return Data(head[head.startIndex..<nl])
    }

    /// The thread id at the end of a rollout file name (a UUID, 36 characters).
    static func codexThread(_ url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.count > 36 ? String(stem.suffix(36)) : stem
    }

    /// Reads what was appended to each source since the last scan. Returns true when anything changed.
    @discardableResult
    public static func scan(_ ledger: inout TokenLedger, sources: [Source], now: Date = Date()) -> Bool {
        var changed = false
        // A cursor outlives the scan window: a session resumed weeks later goes on from where it was read, so its
        // old lines are not counted into the day totals twice. Only files that are gone lose theirs.
        let live = Set(sources.map(\.url.path))
        let gone = ledger.cursors.keys.filter { !live.contains($0) && !FileManager.default.fileExists(atPath: $0) }
        if !gone.isEmpty {
            for k in gone { ledger.cursors[k] = nil }
            changed = true
        }
        for src in sources {
            var cursor = ledger.cursors[src.url.path] ?? LedgerCursor()
            if read(src, cursor: &cursor, into: &ledger) { changed = true }
            if ledger.cursors[src.url.path] != cursor { ledger.cursors[src.url.path] = cursor; changed = true }
        }
        let before = ledger.buckets.count
        ledger.prune(now: now)
        return changed || before != ledger.buckets.count
    }

    /// Reads whole lines from the cursor on, in chunks so a 100 MB transcript never sits in memory at once.
    static func read(_ src: Source, cursor: inout LedgerCursor, into ledger: inout TokenLedger) -> Bool {
        guard let h = FileHandle(forReadingAtPath: src.url.path) else { return false }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < cursor.offset { cursor = LedgerCursor() }   // rewritten or truncated: start over
        guard size > cursor.offset else { return false }
        try? h.seek(toOffset: cursor.offset)
        var changed = false
        var carry = Data()
        let chunk = 4 << 20
        while true {
            guard let data = try? h.read(upToCount: chunk), !data.isEmpty else { break }
            var buf = carry + data
            guard let lastNewline = buf.lastIndex(of: 0x0A) else { carry = buf; continue }
            let complete = buf[buf.startIndex...lastNewline]
            carry = Data(buf[(lastNewline + 1)...])
            buf = Data()
            for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
                if take(Data(line), src: src, cursor: &cursor, into: &ledger) { changed = true }
            }
            cursor.offset += UInt64(complete.count)
        }
        return changed
    }

    /// False when the message was counted already (agents write a message again as it fills in).
    static func remember(_ id: String, in cursor: inout LedgerCursor) -> Bool {
        if cursor.recentIds.contains(id) { return false }
        cursor.recentIds.append(id)
        if cursor.recentIds.count > 64 { cursor.recentIds.removeFirst(cursor.recentIds.count - 64) }
        return true
    }

    static func take(_ line: Data, src: Source, cursor: inout LedgerCursor, into ledger: inout TokenLedger) -> Bool {
        switch src.provider {
        case .claude:
            if ledger.folders[src.session] == nil, line.range(of: Data("\"cwd\"".utf8)) != nil,
               let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let cwd = obj["cwd"] as? String {
                ledger.folders[src.session] = cwd
            }
            if let t = TranscriptLines.claudeTitle(line) { ledger.titles[src.session] = t; return true }
            guard let (id, call) = TranscriptLines.claude(line) else { return false }
            if let id { if !remember(id, in: &cursor) { return false } }
            ledger.add(call, provider: .claude, session: src.session)
            return true
        case .codex:
            if ledger.folders[src.session] == nil, line.range(of: Data("\"session_meta\"".utf8)) != nil,
               let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let cwd = (obj["payload"] as? [String: Any])?["cwd"] as? String {
                ledger.folders[src.session] = cwd
            }
            guard let call = TranscriptLines.codex(line, cursor: &cursor) else { return false }
            ledger.add(call, provider: .codex, session: src.session)
            return true
        case .gemini:
            guard let (id, call) = TranscriptLines.gemini(line) else {
                if ledger.folders[src.session] == nil, let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   let dirs = obj["directories"] as? [String], let d = dirs.first { ledger.folders[src.session] = d }
                return false
            }
            if let id { if !remember(id, in: &cursor) { return false } }
            ledger.add(call, provider: .gemini, session: src.session)
            return true
        case .opencode:
            guard let (id, call, cwd) = TranscriptLines.opencode(line) else { return false }
            if ledger.folders[src.session] == nil, let cwd { ledger.folders[src.session] = cwd }
            if let id { if !remember(id, in: &cursor) { return false } }
            ledger.add(call, provider: .opencode, session: src.session)
            return true
        case .task:
            return false
        }
    }
}
