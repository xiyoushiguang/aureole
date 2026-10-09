import AppKit
import Combine
import UserNotifications
import AureoleCore

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshots: [ProviderID: ProviderSnapshot] = [:]
    @Published private(set) var status: [ProviderID: ProviderStatus] = [:]
    @Published private(set) var predictions: [ProviderID: Prediction] = [:]
    /// Average-pace forecasts for each provider's long (weekly) windows, by window key.
    @Published private(set) var weeklyForecasts: [ProviderID: [String: Prediction]] = [:]
    @Published private(set) var routingHint: RoutingHint?
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var lastChannelError: String?

    let history = HistoryStore()
    let settings: SettingsStore
    private var detector = EventDetector()
    private var timer: Timer?
    private var inFlight: Set<ProviderID> = []
    private var nextDue: [ProviderID: Date] = [:]
    private var backoff: [ProviderID: TimeInterval] = [:]
    /// Consecutive fetches whose numbers did not move; drives the adaptive interval.
    private var unchanged: [ProviderID: Int] = [:]
    /// When Claude Code's status line last handed us fresher numbers than the endpoint had.
    private var lastFeedAt: Date?
    private var lastSummary: [ProviderID: String] = [:]
    private static let snapshotsURL = AureolePaths.appSupport.appendingPathComponent("snapshots.json")
    private var cancellables: Set<AnyCancellable> = []

    init(settings: SettingsStore) {
        self.settings = settings
        let sent = (try? Data(contentsOf: Self.sentURL)).flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
        detector = EventDetector(thresholds: [settings.thresholdWarn, settings.thresholdCritical], sent: sent)
        // Show the last known numbers immediately instead of "Loading…", and don't hammer the endpoints on a quick relaunch.
        if let data = try? Data(contentsOf: Self.snapshotsURL),
           let saved = try? JSONDecoder.aureole.decode([String: ProviderSnapshot].self, from: data) {
            for (key, snap) in saved {
                if let id = ProviderID(rawValue: key), settings.isEnabled(id) {
                    snapshots[id] = snap
                    status[id] = .ok
                    lastRefresh = max(lastRefresh ?? .distantPast, snap.fetchedAt)
                }
            }
        }
        settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.settingsChanged() }
        }.store(in: &cancellables)
    }

    func start() {
        for id in ProviderID.allCases where settings.isEnabled(id) {
            if let s = snapshots[id], Date().timeIntervalSince(s.fetchedAt) < 45 {
                nextDue[id] = s.fetchedAt.addingTimeInterval(45)
            } else {
                refresh(id)
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func settingsChanged() {
        detector.thresholds = [settings.thresholdWarn, settings.thresholdCritical].sorted()
        for id in ProviderID.allCases where !settings.isEnabled(id) {
            snapshots[id] = nil
            status[id] = nil
            predictions[id] = nil
            weeklyForecasts[id] = nil
        }
        routingHint = settings.routingHints ? RoutingHint.evaluate(snapshots, drainedAt: Double(settings.thresholdWarn)) : nil
        objectWillChange.send()
    }

    private func tick() {
        ingestStatusline()
        let now = Date()
        for id in ProviderID.allCases where settings.isEnabled(id) {
            if let due = nextDue[id], due > now { continue }
            refresh(id)
        }
    }

    func refreshAll(force: Bool) {
        for id in ProviderID.allCases where settings.isEnabled(id) {
            if force { backoff[id] = nil }
            refresh(id)
        }
    }

    private func provider(for id: ProviderID) -> any UsageProvider {
        switch id {
        case .claude: return ClaudeProvider(credentialSource: settings.claudeCredentialSource)
        case .codex: return CodexProvider()
        }
    }

    private func refresh(_ id: ProviderID) {
        guard !inFlight.contains(id) else { return }
        inFlight.insert(id)
        if snapshots[id] == nil { status[id] = .loading }
        nextDue[id] = Date().addingTimeInterval(settings.refreshInterval)
        let provider = provider(for: id)
        Task { [weak self] in
            do {
                let snap = try await provider.fetch()
                await MainActor.run { self?.apply(snap) }
            } catch {
                await MainActor.run { self?.handle(error, for: id) }
            }
        }
    }

    /// Base interval while numbers move; doubles after three unchanged fetches, capped at five minutes.
    /// While Claude Code's status line keeps the 5-hour and weekly numbers fresh, the endpoint is only
    /// asked every ten minutes, for the windows the status line does not carry.
    private func interval(for id: ProviderID) -> TimeInterval {
        let base = settings.refreshInterval
        let n = unchanged[id] ?? 0
        let adaptive = n >= 3 ? min(300, base * pow(2, Double(min(n - 2, 4)))) : base
        if id == .claude, let fed = lastFeedAt, Date().timeIntervalSince(fed) < 600 { return max(adaptive, 600) }
        return adaptive
    }

    /// Takes the newest status line reading when it is newer than what the endpoint last said.
    private func ingestStatusline() {
        guard settings.isEnabled(.claude),
              let feed = StatuslineFiles.loadAll().filter(\.hasLimits).max(by: { $0.at < $1.at }),
              feed.at > (snapshots[.claude]?.fetchedAt ?? .distantPast).addingTimeInterval(1) else { return }
        lastFeedAt = feed.at
        ingest(feed.merged(into: snapshots[.claude]), source: "status line")
    }

    private func persistSnapshots() {
        var dict: [String: ProviderSnapshot] = [:]
        for (id, snap) in snapshots { dict[id.rawValue] = snap }
        if let data = try? JSONEncoder.aureole.encode(dict) {
            try? data.write(to: Self.snapshotsURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.snapshotsURL.path)
        }
    }

    private func apply(_ snap: ProviderSnapshot) {
        let id = snap.provider
        inFlight.remove(id)
        backoff[id] = nil
        let previous = snapshots[id]
        let moved = previous.map { prev in
            snap.windows.contains { w in prev.windows.first { $0.key == w.key }?.usedPercent != w.usedPercent }
        } ?? true
        unchanged[id] = moved ? 0 : (unchanged[id] ?? 0) + 1
        nextDue[id] = Date().addingTimeInterval(interval(for: id))
        ingest(snap, source: "endpoint")
    }

    /// Records a snapshot from either source and derives forecasts and alerts from it.
    private func ingest(_ snap: ProviderSnapshot, source: String) {
        let id = snap.provider
        let previous = snapshots[id]
        snapshots[id] = snap
        status[id] = .ok
        lastRefresh = snap.fetchedAt
        persistSnapshots()
        history.append(snap)
        var prediction: Prediction?
        if let primary = snap.primary {
            prediction = Predictor.forecast(primary, samples: history.samples(provider: id, key: primary.key))
        }
        predictions[id] = prediction
        var weekly: [String: Prediction] = [:]
        for w in snap.windows { if let p = Predictor.windowPace(w) { weekly[w.key] = p } }
        weeklyForecasts[id] = weekly
        routingHint = settings.routingHints ? RoutingHint.evaluate(snapshots, drainedAt: Double(settings.thresholdWarn)) : nil
        let summary = snap.windows.map { "\($0.label)=\(Int($0.usedPercent))%" }.joined(separator: " ")
        // The status line updates on every reply; only log when the numbers change.
        if source == "endpoint" || summary != lastSummary[id] {
            AureoleLog.shared.log("\(id.displayName) (\(source)): \(summary) plan=\(snap.planLabel ?? "-")")
        }
        lastSummary[id] = summary
        let events = detector.detect(previous: previous, current: snap, prediction: prediction, weekly: weekly)
        dispatch(events)
    }

    private func handle(_ error: Error, for id: ProviderID) {
        inFlight.remove(id)
        let message = (error as? ProviderError)?.errorDescription ?? error.localizedDescription
        if case .rateLimited(let retryAfter)? = error as? ProviderError {
            // Obey Retry-After when the server sends one; otherwise back off 2→4→8→15 min.
            let delay = retryAfter ?? min(900, (backoff[id] ?? 60) * 2)
            backoff[id] = delay
            nextDue[id] = Date().addingTimeInterval(delay)
            status[id] = .rateLimited(until: nextDue[id]!)
            AureoleLog.shared.log("\(id.displayName) rate limited (retry in \(Int(delay))s\(retryAfter != nil ? ", server asked" : ""))")
            return
        }
        let wasOK: Bool = { if case .ok? = status[id] { return true } else { return false } }()
        if case .signedOut = error as? ProviderError {
            status[id] = .signedOut(message)
            if wasOK, let e = detector.authLost(id, message: message) { dispatch([e]) }
        } else {
            status[id] = .error(message)
        }
        let delay = min(15 * 60, (backoff[id] ?? 60) * 2)
        backoff[id] = delay
        nextDue[id] = Date().addingTimeInterval(delay)
        AureoleLog.shared.log("\(id.displayName) failed: \(message) (retry in \(Int(delay))s)")
    }

    private static let sentURL = AureolePaths.appSupport.appendingPathComponent("events.json")

    private func persistSent() {
        if let data = try? JSONEncoder().encode(detector.sent) {
            try? data.write(to: Self.sentURL, options: .atomic)
        }
    }

    func dispatch(_ events: [UsageEvent]) {
        guard !events.isEmpty else { return }
        persistSent()
        for event in events {
            AureoleLog.shared.log("event \(event.kind): \(event.title)")
            if settings.nativeNotifications { NativeNotifier.send(event) }
            for channel in settings.channels where channel.enabled && channel.kind != .native {
                send(event, to: channel)
            }
        }
    }

    func send(_ event: UsageEvent, to channel: ChannelConfig) {
        Task { [weak self] in
            do {
                try await ChannelDispatcher.send(event, to: channel)
                AureoleLog.shared.log("sent to \(channel.name)")
            } catch {
                let msg = "\(channel.name): \(error.localizedDescription)"
                AureoleLog.shared.log("channel failed \(msg)")
                await MainActor.run { self?.lastChannelError = msg }
            }
        }
    }

    /// A synthetic event for the "Send test" button.
    func sendTest(to channel: ChannelConfig) {
        let window = UsageWindow(key: "five_hour", label: "5h", kind: .fiveHour, usedPercent: 81,
                                 resetsAt: Date().addingTimeInterval(2 * 3600 + 13 * 60), duration: 5 * 3600)
        let event = UsageEvent.threshold(provider: .claude, window: window, level: 80)
        if channel.kind == .native { NativeNotifier.send(event) } else { send(event, to: channel) }
    }
}

enum NativeNotifier {
    private static var authorized = false

    static func send(_ event: UsageEvent) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let deliver = {
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body
            content.sound = .default
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(req) { error in
                if let error { AureoleLog.shared.log("native notification failed: \(error.localizedDescription)") }
            }
        }
        if authorized { deliver(); return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            authorized = granted
            if granted {
                deliver()
            } else {
                // Without this line a refused or failed request looked exactly like a delivered notification.
                AureoleLog.shared.log("notifications not allowed: \(error.map { "\($0)" } ?? "the user has turned them off in System Settings")")
            }
        }
    }
}
