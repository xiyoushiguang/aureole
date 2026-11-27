import AppKit
import Combine
import Network
import UserNotifications
import AureoleCore

@MainActor
final class UsageStore: ObservableObject {
    /// What the panel shows: each provider's last reading, with any window that has reset since shown empty.
    @Published private(set) var snapshots: [ProviderID: ProviderSnapshot] = [:]
    @Published private(set) var status: [ProviderID: ProviderStatus] = [:]
    @Published private(set) var predictions: [ProviderID: Prediction] = [:]
    /// Average-pace forecasts for each provider's long (weekly) windows, by window key.
    @Published private(set) var weeklyForecasts: [ProviderID: [String: Prediction]] = [:]
    @Published private(set) var routingHint: RoutingHint?
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var lastChannelError: String?
    /// Providers whose numbers are old because reading them keeps failing. Drawn dimmed, so a number from
    /// days ago is never taken for the current one.
    @Published private(set) var stale: Set<ProviderID> = []
    static let staleAfter: TimeInterval = 10 * 60

    private(set) var history: HistoryStore
    let settings: SettingsStore
    /// Sample numbers for `--demo` and snapshots: nothing is fetched, saved or sent.
    private(set) var demo = false
    /// True while an agent is inside a turn somewhere, so the numbers can move any minute. Set by the app.
    var agentsBusy: () -> Bool = { false }

    /// The readings as they came in; `snapshots` is these, rolled over to now.
    private var readings: [ProviderID: ProviderSnapshot] = [:]
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
    private var pathMonitor: NWPathMonitor?
    private var lastPath: String?
    /// The display is asleep.
    private var dark = false
    /// The screen is locked or the display is off: nobody is looking.
    private var away: Bool { dark || Self.screenIsLocked() }

    /// Asked of the login session each time, so a missed notification cannot leave it wrong.
    private static func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
    /// Since when each provider's token has been past its expiry time.
    private var expiredSince: [ProviderID: Date] = [:]
    /// When an expired token was last tried anyway (see `provider(for:probe:)`).
    private var lastProbe: [ProviderID: Date] = [:]
    private var lastNudge: [ProviderID: Date] = [:]
    /// The reset each provider was last asked about right after it passed, and when that was.
    private var chasedReset: [ProviderID: Date] = [:]
    private var lastChase: [ProviderID: Date] = [:]
    private var lastFailureLog: [ProviderID: (message: String, at: Date)] = [:]
    /// Codex's sign-in file as it was when reading last failed for want of a good token.
    private var codexAuthStamp: Date?
    private var persistedWindows: [ProviderID: [UsageWindow]] = [:]
    private var lastPersist = Date.distantPast

    init(settings: SettingsStore, demo: Bool = false) {
        self.settings = settings
        self.demo = demo
        history = demo ? HistoryStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("aureole-demo-\(UUID().uuidString).json"))
                       : HistoryStore()
        guard !demo else { return }
        let sent = (try? Data(contentsOf: Self.sentURL)).flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
        detector = EventDetector(thresholds: [settings.thresholdWarn, settings.thresholdCritical], sent: sent)
        // Show the last known numbers immediately instead of "Loading…", and don't hammer the endpoints on a quick relaunch.
        if let data = try? Data(contentsOf: Self.snapshotsURL),
           let saved = try? JSONDecoder.aureole.decode([String: ProviderSnapshot].self, from: data) {
            for (key, snap) in saved {
                if let id = ProviderID(rawValue: key), settings.isEnabled(id) {
                    readings[id] = snap
                    snapshots[id] = snap.rolledOver()
                    status[id] = .ok
                    lastRefresh = max(lastRefresh ?? .distantPast, snap.fetchedAt)
                }
            }
            persistedWindows = readings.mapValues(\.windows)
        }
        settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.settingsChanged() }
        }.store(in: &cancellables)
    }

    /// Shows fixed numbers with their history, as if they had been read; for `--demo` and snapshots.
    func loadDemo(_ history: [ProviderSnapshot]) {
        for snap in history.sorted(by: { $0.fetchedAt < $1.fetchedAt }) { self.history.append(snap) }
        for id in ProviderID.allCases {
            guard let snap = history.filter({ $0.provider == id }).max(by: { $0.fetchedAt < $1.fetchedAt }) else { continue }
            readings[id] = snap
            snapshots[id] = snap
            status[id] = .ok
            lastRefresh = snap.fetchedAt
            if let primary = snap.primary {
                predictions[id] = Predictor.forecast(primary, samples: self.history.samples(provider: id, key: primary.key), now: snap.fetchedAt)
            }
            var weekly: [String: Prediction] = [:]
            for w in snap.windows { if let p = Predictor.windowPace(w, now: snap.fetchedAt) { weekly[w.key] = p } }
            weeklyForecasts[id] = weekly
        }
    }

    /// The demo's numbers started over with another afternoon (`--tour` walks one through the four skies).
    func reloadDemo(_ history: [ProviderSnapshot]) {
        guard demo else { return }
        self.history = HistoryStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("aureole-demo-\(UUID().uuidString).json"))
        loadDemo(history)
    }

    /// A provider that cannot be read, with its numbers gone stale; for snapshots of that state.
    func loadDemoTrouble(_ id: ProviderID, _ trouble: ProviderStatus?) {
        guard demo else { return }
        if let trouble {
            status[id] = trouble
            stale.insert(id)
        } else {
            status[id] = .ok
            stale.remove(id)
        }
    }

    func start() {
        guard !demo else { return }
        for id in ProviderID.allCases where settings.isEnabled(id) {
            if let s = readings[id], Date().timeIntervalSince(s.fetchedAt) < 45 {
                nextDue[id] = s.fetchedAt.addingTimeInterval(45)
            } else {
                refresh(id)
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        watchConnectivity()
        watchPresence()
    }

    /// After a wake or a network change (Wi-Fi, VPN, proxy app), a provider that failed is asked again
    /// within seconds instead of waiting out a back-off of up to 15 minutes.
    private func watchConnectivity() {
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.retryFailed(reason: "wake") } }
            .store(in: &cancellables)
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let key = path.status == .satisfied
                ? "up " + path.availableInterfaces.map(\.name).joined(separator: ",")
                : "down"
            DispatchQueue.main.async {
                guard let self else { return }
                let previous = self.lastPath
                self.lastPath = key
                if previous != nil, previous != key, path.status == .satisfied { self.retryFailed(reason: "network change") }
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.aureole.path"))
        pathMonitor = monitor
    }

    /// With the screen locked or the display off and no agent at work, nobody sees the numbers and nothing
    /// moves them, so they are read every half hour instead of every few minutes. Coming back reads at once.
    private func watchPresence() {
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (UsageStore) -> Void) {
            center.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { if let self { action(self) } } }
                .store(in: &cancellables)
        }
        on(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.nudge("unlocked") }
        on(workspace, NSWorkspace.screensDidSleepNotification) { $0.dark = true }
        on(workspace, NSWorkspace.screensDidWakeNotification) { $0.dark = false; $0.nudge("display on") }
    }

    private func retryFailed(reason: String) {
        var asked: [String] = []
        for id in ProviderID.allCases where settings.isEnabled(id) {
            guard case .error? = status[id] else { continue }
            backoff[id] = nil
            // Give the new route a few seconds to settle.
            nextDue[id] = Date().addingTimeInterval(3)
            asked.append(id.displayName)
        }
        if !asked.isEmpty { AureoleLog.shared.log("\(reason): retrying \(asked.joined(separator: ", ")) shortly") }
    }

    /// Someone is back or about to look (an unlock, the panel opening), or an agent has started work: read
    /// again now wherever the numbers are older than a refresh interval. At most once a minute per provider,
    /// and never into a rate limit.
    func nudge(_ reason: String) {
        guard !demo else { return }
        let now = Date()
        let fresh = max(60, settings.refreshInterval)
        var asked: [String] = []
        for id in ProviderID.allCases where settings.isEnabled(id) && !inFlight.contains(id) {
            if case .rateLimited(let until)? = status[id], until > now { continue }
            if let r = readings[id], now.timeIntervalSince(r.fetchedAt) < fresh { continue }
            if let last = lastNudge[id], now.timeIntervalSince(last) < 60 { continue }
            guard (nextDue[id] ?? .distantPast) > now.addingTimeInterval(3) else { continue }
            lastNudge[id] = now
            backoff[id] = nil
            nextDue[id] = now.addingTimeInterval(1)
            asked.append(id.displayName)
        }
        if !asked.isEmpty { AureoleLog.shared.log("\(reason): reading \(asked.joined(separator: ", ")) now") }
    }

    private func settingsChanged() {
        detector.thresholds = [settings.thresholdWarn, settings.thresholdCritical].sorted()
        for id in ProviderID.allCases where !settings.isEnabled(id) {
            readings[id] = nil
            snapshots[id] = nil
            status[id] = nil
            predictions[id] = nil
            weeklyForecasts[id] = nil
            stale.remove(id)
        }
        routingHint = settings.routingHints ? RoutingHint.evaluate(snapshots, drainedAt: Double(settings.thresholdWarn)) : nil
        objectWillChange.send()
    }

    private func tick() {
        ingestStatusline()
        let now = Date()
        settle(now)
        for id in ProviderID.allCases where settings.isEnabled(id) {
            if let due = nextDue[id], due > now { continue }
            refresh(id)
        }
    }

    /// Keeps what is shown true to the clock between readings.
    private func settle(_ now: Date) {
        var old: Set<ProviderID> = []
        for id in ProviderID.allCases where settings.isEnabled(id) {
            guard let reading = readings[id] else { continue }
            // A window whose reset has passed is empty, whatever the last reading said.
            let shown = reading.rolledOver(now: now)
            if snapshots[id] != shown {
                snapshots[id] = shown
                // The forecasts were made for the window that just ended.
                if shown.primary != reading.primary { predictions[id] = nil }
                var weekly: [String: Prediction] = [:]
                for w in shown.windows { if let p = Predictor.windowPace(w, now: now) { weekly[w.key] = p } }
                weeklyForecasts[id] = weekly
                routingHint = settings.routingHints ? RoutingHint.evaluate(snapshots, drainedAt: Double(settings.thresholdWarn)) : nil
            }
            // Ask right after a reset we know of, instead of waiting out a slow interval.
            // (Not more than once in five minutes, whatever reset times a vendor comes up with.)
            if let reset = reading.nextReset, now >= reset.addingTimeInterval(20), chasedReset[id] != reset,
               now.timeIntervalSince(lastChase[id] ?? .distantPast) >= 300 {
                chasedReset[id] = reset
                lastChase[id] = now
                if status[id]?.isFailing != true, (nextDue[id] ?? .distantPast) > now { nextDue[id] = now }
            }
            if status[id]?.isFailing == true, now.timeIntervalSince(reading.fetchedAt) > Self.staleAfter { old.insert(id) }
        }
        if old != stale { stale = old }
        watchCodexSignIn(now)
    }

    /// While Codex cannot be read for want of a good token, a rewritten sign-in file means there may be one.
    private func watchCodexSignIn(_ now: Date) {
        let waiting: Bool = {
            guard settings.isEnabled(.codex) else { return false }
            switch status[.codex] {
            case .signedOut?, .expired?: return true
            default: return false
            }
        }()
        guard waiting else { codexAuthStamp = nil; return }
        let path = CodexProvider().authURL.path
        guard let stamp = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return }
        if let seen = codexAuthStamp, seen != stamp, !inFlight.contains(.codex) {
            backoff[.codex] = nil
            nextDue[.codex] = now
        }
        codexAuthStamp = stamp
    }

    func refreshAll(force: Bool) {
        for id in ProviderID.allCases where settings.isEnabled(id) {
            if force { backoff[id] = nil }
            refresh(id, probe: force)
        }
    }

    /// An expired token is not tried: the answer is known. Except when asked to (`probe`, the Refresh button)
    /// and once an hour, in case an expiry time has stopped meaning what it says.
    private func provider(for id: ProviderID, probe: Bool) -> any UsageProvider {
        var asks = probe
        if case .expired? = status[id], Date().timeIntervalSince(lastProbe[id] ?? .distantPast) >= 3600 { asks = true }
        if asks { lastProbe[id] = Date() }
        switch id {
        case .claude:
            var p = ClaudeProvider(credentialSource: settings.claudeCredentialSource)
            p.skipWhenExpired = !asks
            return p
        case .codex, .task, .gemini, .opencode:
            var p = CodexProvider()
            p.skipWhenExpired = !asks
            return p
        }
    }

    private func refresh(_ id: ProviderID, probe: Bool = false) {
        guard !inFlight.contains(id) else { return }
        inFlight.insert(id)
        let provider = provider(for: id, probe: probe)
        if readings[id] == nil, status[id]?.isFailing != true { status[id] = .loading }
        nextDue[id] = Date().addingTimeInterval(settings.refreshInterval)
        Task { [weak self] in
            do {
                let snap = try await provider.fetch()
                await MainActor.run { self?.apply(snap) }
            } catch {
                await MainActor.run { self?.handle(error, for: id) }
            }
        }
    }

    /// Base interval while numbers move; doubles after three unchanged fetches. With an agent at work that
    /// stops at five minutes; with none, at fifteen; and with nobody at the screen either, every reading is
    /// half an hour apart. While Claude Code's status line keeps the 5-hour and weekly numbers fresh, the
    /// endpoint is only asked every ten minutes, for the windows the status line does not carry.
    private func interval(for id: ProviderID) -> TimeInterval {
        let base = settings.refreshInterval
        let n = unchanged[id] ?? 0
        let fed = lastFeedAt.map { Date().timeIntervalSince($0) < 600 } ?? false
        let busy = agentsBusy() || fed
        let cap: TimeInterval = busy ? 300 : 900
        var adaptive = n >= 3 ? min(cap, base * pow(2, Double(min(n - 2, 5)))) : base
        if !busy, away { adaptive = max(adaptive, Self.awayInterval) }
        if id == .claude, fed { return max(adaptive, 600) }
        return adaptive
    }
    static let awayInterval: TimeInterval = 30 * 60

    /// Takes the newest status line reading when it is newer than what the endpoint last said.
    private func ingestStatusline() {
        guard settings.isEnabled(.claude),
              let feed = StatuslineFiles.loadAll().filter(\.hasLimits).max(by: { $0.at < $1.at }),
              feed.at > (readings[.claude]?.fetchedAt ?? .distantPast).addingTimeInterval(1) else { return }
        lastFeedAt = feed.at
        // The windows the status line does not carry stay as last read, emptied if they have reset since.
        ingest(feed.merged(into: readings[.claude]?.rolledOver(now: feed.at)), fromEndpoint: false, previous: readings[.claude])
    }

    /// The file is small but written on every reading: only when a number moved, else once a minute.
    private func persistSnapshots(force: Bool = false) {
        let now = Date()
        let windows = readings.mapValues(\.windows)
        guard force || windows != persistedWindows || now.timeIntervalSince(lastPersist) >= 60 else { return }
        persistedWindows = windows
        lastPersist = now
        var dict: [String: ProviderSnapshot] = [:]
        for (id, snap) in readings { dict[id.rawValue] = snap }
        if let data = try? JSONEncoder.aureole.encode(dict) {
            try? data.write(to: Self.snapshotsURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.snapshotsURL.path)
        }
    }

    /// Writes what is only in memory, now. For when the app is about to quit.
    func flush() {
        guard !demo else { return }
        persistSnapshots(force: true)
        history.flush()
    }

    private func apply(_ snap: ProviderSnapshot) {
        let id = snap.provider
        inFlight.remove(id)
        backoff[id] = nil
        let previous = readings[id]
        let moved = previous.map { prev in
            snap.windows.contains { w in prev.windows.first { $0.key == w.key }?.usedPercent != w.usedPercent }
        } ?? true
        unchanged[id] = moved ? 0 : (unchanged[id] ?? 0) + 1
        nextDue[id] = Date().addingTimeInterval(interval(for: id))
        ingest(snap, fromEndpoint: true, previous: previous)
    }

    /// Records a snapshot from either source and derives forecasts and alerts from it.
    private func ingest(_ snap: ProviderSnapshot, fromEndpoint: Bool, previous: ProviderSnapshot?) {
        let id = snap.provider
        readings[id] = snap
        snapshots[id] = snap.rolledOver()
        stale.remove(id)
        // Numbers from the status line say nothing about the stored token or the network: only the endpoint
        // answering ends a failure. Until it does, the numbers are current and the reason stays on show,
        // instead of coming and going with every status line update.
        if fromEndpoint {
            status[id] = .ok
            detector.refusalsEnded(id)
            expiredSince[id] = nil
            lastFailureLog[id] = nil
        } else if status[id]?.isFailing != true {
            status[id] = .ok
        }
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
        // Both sources repeat themselves for hours when nothing is used: only a change is worth a line.
        if summary != lastSummary[id] {
            AureoleLog.shared.log("\(id.displayName) (\(fromEndpoint ? "endpoint" : "status line")): \(summary) plan=\(snap.planLabel ?? "-")")
        }
        lastSummary[id] = summary
        let events = detector.detect(previous: previous, current: snap, prediction: prediction, weekly: weekly)
        dispatch(events)
    }

    private func handle(_ error: Error, for id: ProviderID) {
        inFlight.remove(id)
        let now = Date()
        let message = (error as? ProviderError)?.errorDescription ?? error.localizedDescription
        switch error as? ProviderError {
        case .rateLimited(let retryAfter)?:
            // Obey Retry-After when the server sends one; otherwise back off 2→4→8→15 min.
            let delay = retryAfter ?? min(900, (backoff[id] ?? 60) * 2)
            backoff[id] = delay
            nextDue[id] = now.addingTimeInterval(delay)
            status[id] = .rateLimited(until: nextDue[id]!)
            AureoleLog.shared.log("\(id.displayName) rate limited (retry in \(Int(delay))s\(retryAfter != nil ? ", server asked" : ""))")
        case .expired(let note)?:
            // Nothing is wrong: the agent's CLI writes a fresh token the next time it runs. Looking for it costs
            // no request, so look often while the CLI was probably just in use, then rarely.
            if expiredSince[id] == nil {
                expiredSince[id] = now
                lastProbe[id] = now
                AureoleLog.shared.log("\(id.displayName): token expired, waiting for its CLI to renew it")
            }
            status[id] = .expired(note)
            detector.refusalsEnded(id)
            backoff[id] = nil
            let waited = now.timeIntervalSince(expiredSince[id] ?? now)
            var delay: TimeInterval = waited < 30 * 60 ? 120 : 600
            if away, !agentsBusy() { delay = max(delay, Self.awayInterval) }
            nextDue[id] = now.addingTimeInterval(delay)
        case .signedOut?:
            // A reading less than a day old: this sign-in was working, so there is something to lose. (A provider
            // that was never signed in, or was left signed out long ago, is not worth a notification.)
            let wasWorking = readings[id].map { now.timeIntervalSince($0.fetchedAt) < 86400 } ?? false
            status[id] = .signedOut(message)
            if let e = detector.refused(id, message: message, wasWorking: wasWorking, now: now) { dispatch([e]) }
            // Most refusals end within minutes, when a fresh token is written: ask again soon at first.
            var delay: TimeInterval = 180
            if detector.refusalIsFresh(id, now: now) {
                backoff[id] = nil
            } else {
                delay = min(15 * 60, (backoff[id] ?? 60) * 2)
                backoff[id] = delay
            }
            nextDue[id] = now.addingTimeInterval(delay)
            logFailure(id, message, retryIn: delay, now: now)
        default:
            status[id] = .error(message)
            let delay = min(15 * 60, (backoff[id] ?? 60) * 2)
            backoff[id] = delay
            nextDue[id] = now.addingTimeInterval(delay)
            logFailure(id, message, retryIn: delay, now: now)
        }
    }

    /// A failure that repeats for days is one line when it starts and one an hour after that, not one per try.
    private func logFailure(_ id: ProviderID, _ message: String, retryIn delay: TimeInterval, now: Date) {
        if let last = lastFailureLog[id], last.message == message, now.timeIntervalSince(last.at) < 3600 { return }
        lastFailureLog[id] = (message, now)
        AureoleLog.shared.log("\(id.displayName) failed: \(message) (retry in \(Int(delay))s)")
    }

    private static let sentURL = AureolePaths.appSupport.appendingPathComponent("events.json")

    private func persistSent() {
        if let data = try? JSONEncoder().encode(detector.sent) {
            try? data.write(to: Self.sentURL, options: .atomic)
        }
    }

    func dispatch(_ events: [UsageEvent]) {
        guard !events.isEmpty, !demo else { return }
        // Asked to keep names and commands to the panel: they are taken out here, before the log and every channel.
        let events = settings.notifyHideDetails ? events.map(\.withoutDetails) : events
        persistSent()
        if let quiet = settings.quietHours, quiet.contains(Date()) {
            for event in events { AureoleLog.shared.log("event \(event.kind) held back (quiet hours): \(event.title)") }
            return
        }
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
