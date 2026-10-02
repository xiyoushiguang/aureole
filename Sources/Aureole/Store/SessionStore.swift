import AppKit
import Combine
import AureoleCore

/// Watches the session files the hook helper writes and keeps a grouped board for the panel.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var board = SessionBoard()
    @Published private(set) var sessions: [AgentSession] = []
    /// Context tokens per session, read lazily from each transcript's tail.
    @Published private(set) var context: [String: Int] = [:]
    /// Conversation titles Claude Code generates, read from the same transcript tail.
    @Published private(set) var titles: [String: String] = [:]
    @Published private(set) var hookStatus: HookInstaller.Status = .notInstalled
    @Published private(set) var lastError: String?

    let settings: SettingsStore
    /// Where wait/done alerts go; the app points this at the usage store's channels.
    var onEvents: (([UsageEvent]) -> Void)?
    private var alerts = SessionAlerts(waitingAfter: 120, announceDone: true)
    /// Finished sessions you have looked at: session id → the finish time you saw. Kept across launches.
    private var seen: [String: Double] = UserDefaults.standard.dictionary(forKey: "seenSessions") as? [String: Double] ?? [:]
    private let directory = SessionFiles.directory
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var timer: Timer?
    private var reloadWork: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []
    private var contextChecked: [String: Date] = [:]
    private let contextQueue = DispatchQueue(label: "app.aureole.context", qos: .utility)

    /// Where the hook helper lives once installed; settings.json points here, not into the app bundle, so the app can move.
    static let helperURL = AureolePaths.appSupport.appendingPathComponent("aureole-hook")

    init(settings: SettingsStore) {
        self.settings = settings
        settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        }.store(in: &cancellables)
    }

    func start() {
        installHelperIfNeeded()
        refreshHookStatus()
        reload()
        watch()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reload()
                // "waited 4m" has to keep counting even when no file changed.
                if !self.board.isEmpty { self.objectWillChange.send() }
            }
        }
    }

    // MARK: - Files

    private func watch() {
        fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        src.setCancelHandler { [fd] in close(fd) }
        src.resume()
        source = src
    }

    /// Hooks write several files in a burst; coalesce into one reload.
    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.reload() } }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func reload() {
        guard settings.sessionsEnabled else {
            if !sessions.isEmpty { sessions = []; board = SessionBoard() }
            return
        }
        let now = Date()
        let all = SessionFiles.loadAll(in: directory)
        var live: [AgentSession] = []
        for s in all {
            let alive = Self.isAlive(s)
            // A dead agent or a file nobody touched for hours is history; drop the file so the folder stays small.
            if !alive || now.timeIntervalSince(s.updatedAt) > SessionBoard.staleAfter {
                try? FileManager.default.removeItem(at: SessionFiles.url(for: s.sessionId, in: directory))
                continue
            }
            live.append(s)
        }
        let newBoard = SessionBoard.build(live, now: now, alive: { _ in true }, seen: { [seen] s in
            seen[s.sessionId].map { abs($0 - s.stateSince.timeIntervalSince1970) < 1 } ?? false
        })
        if live != sessions { sessions = live }
        if newBoard != board { board = newBoard }
        refreshContext(for: live, now: now)
        alerts.waitingAfter = settings.notifyWaitingMinutes > 0 ? TimeInterval(settings.notifyWaitingMinutes * 60) : nil
        alerts.announceDone = settings.notifyDone
        let events = alerts.check(newBoard, now: now, name: name(of:))
        if !events.isEmpty { onEvents?(events) }
    }

    /// You looked at this session (jumped to it), so its finished task is no longer news.
    func acknowledge(_ s: AgentSession) {
        guard SessionBoard.finishedTask(s) else { return }
        seen[s.sessionId] = s.stateSince.timeIntervalSince1970
        let live = Set(sessions.map(\.sessionId))
        seen = seen.filter { live.contains($0.key) }
        UserDefaults.standard.set(seen, forKey: "seenSessions")
        reload()
    }

    /// Transcripts run to tens of MB, so read each tail off the main thread and at most every 15 s per session.
    private func refreshContext(for live: [AgentSession], now: Date) {
        let ids = Set(live.map(\.sessionId))
        for gone in contextChecked.keys where !ids.contains(gone) { context[gone] = nil; titles[gone] = nil; contextChecked[gone] = nil }
        for s in live {
            guard let path = s.transcriptPath, now.timeIntervalSince(contextChecked[s.sessionId] ?? .distantPast) > 15 else { continue }
            contextChecked[s.sessionId] = now
            let id = s.sessionId
            contextQueue.async { [weak self] in
                let summary = TranscriptReader.summary(path: path)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if let tokens = summary.contextTokens, self.context[id] != tokens { self.context[id] = tokens }
                        if let title = summary.title, self.titles[id] != title { self.titles[id] = title }
                    }
                }
            }
        }
    }

    /// kill(pid, 0) answers "does this process exist" without touching it.
    nonisolated static func isAlive(_ s: AgentSession) -> Bool {
        guard let pid = s.agentPid, pid > 1 else { return true }   // unknown pid: trust the file until it goes stale
        return kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: - Hook helper

    /// Copies the bundled helper next to our data when it is missing or older than the app's copy.
    private func installHelperIfNeeded() {
        guard let bundled = Bundle.main.url(forAuxiliaryExecutable: "aureole-hook") else { return }
        let fm = FileManager.default
        let dst = Self.helperURL
        let needsCopy: Bool = {
            guard fm.fileExists(atPath: dst.path),
                  let a = try? fm.attributesOfItem(atPath: bundled.path), let b = try? fm.attributesOfItem(atPath: dst.path) else { return true }
            return (a[.size] as? Int) != (b[.size] as? Int) || ((a[.modificationDate] as? Date) ?? .distantPast) > ((b[.modificationDate] as? Date) ?? .distantPast)
        }()
        guard needsCopy else { return }
        do {
            let tmp = dst.appendingPathExtension("new")
            try? fm.removeItem(at: tmp)
            try fm.copyItem(at: bundled, to: tmp)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
            _ = try fm.replaceItemAt(dst, withItemAt: tmp)
            AureoleLog.shared.log("hook helper updated at \(dst.path)")
        } catch {
            AureoleLog.shared.log("hook helper copy failed: \(error.localizedDescription)")
        }
    }

    func refreshHookStatus() {
        hookStatus = (try? HookInstaller.read()).map { HookInstaller.status(settings: $0) } ?? .notInstalled
    }

    func installHooks() { setHooks(installed: true) }
    func uninstallHooks() { setHooks(installed: false) }

    private func setHooks(installed: Bool) {
        do {
            installHelperIfNeeded()
            let current = try HookInstaller.read()
            let merged = HookInstaller.merge(settings: current, helperPath: Self.helperURL.path, install: installed)
            try HookInstaller.write(merged)
            lastError = nil
            AureoleLog.shared.log(installed ? "Claude Code hooks installed" : "Claude Code hooks removed")
        } catch {
            lastError = error.localizedDescription
            AureoleLog.shared.log("hook install failed: \(error.localizedDescription)")
        }
        refreshHookStatus()
    }

    /// What to call a session on screen: Claude Code's own title when there is one, else the folder.
    func name(of s: AgentSession) -> String { titles[s.sessionId] ?? s.projectName }

    // MARK: - Jump

    /// Brings the terminal that owns the session to the front; falls back to activating its app.
    func jump(to s: AgentSession) {
        TerminalJumper.jump(to: s)
    }
}

enum TerminalJumper {
    @MainActor
    static func jump(to s: AgentSession) {
        if let tty = s.tty, let program = s.termProgram {
            let dev = "/dev/\(tty)"
            switch program {
            case "Apple_Terminal":
                run(script: """
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(dev)" then
                                set selected tab of w to t
                                set index of w to 1
                                activate
                                return
                            end if
                        end repeat
                    end repeat
                end tell
                """)
            case "iTerm.app":
                run(script: """
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "\(dev)" then
                                    select t
                                    select s
                                    activate
                                    return
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                """)
            default:
                break
            }
        }
        if let pane = s.tmuxPane {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["tmux", "select-pane", "-t", pane]
            try? p.run()
        }
        if let id = s.bundleId, let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            app.activate()
        }
    }

    /// Runs in a separate osascript process: an Apple Event to a busy terminal, or one waiting behind an
    /// Automation permission prompt, can block for minutes, and doing that on the main thread froze the panel.
    private static func run(script: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        p.terminationHandler = { proc in
            guard proc.terminationStatus != 0 else { return }
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            AureoleLog.shared.log("terminal jump failed: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        do {
            try p.run()
        } catch {
            AureoleLog.shared.log("terminal jump failed: \(error.localizedDescription)")
            return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            guard p.isRunning else { return }
            p.terminate()
            AureoleLog.shared.log("terminal jump timed out (is Automation permission for the terminal pending?)")
        }
    }
}
