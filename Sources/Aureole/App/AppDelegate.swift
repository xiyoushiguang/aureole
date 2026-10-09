import AppKit
import Combine
import ServiceManagement
import SwiftUI
import AureoleCore

@MainActor
protocol AppActions: AnyObject {
    func openSettings()
    func refreshNow()
    func togglePinned()
    func jump(to session: AgentSession)
    func openWelcome()
    func quit()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, AppActions {
    let settings = SettingsStore()
    private(set) lazy var store = UsageStore(settings: settings)
    private(set) lazy var sessions = SessionStore(settings: settings)
    private var notch: NotchController?
    private var statusItem: StatusItemController?
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AureoleLog.shared.log("Aureole \(AureoleInfo.version) launched")
        statusItem = StatusItemController(store: store, settings: settings, actions: self)
        let controller = NotchController(store: store, sessions: sessions, settings: settings, actions: self)
        notch = controller
        reattach()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reattach() }
        }
        settings.$displayChoice.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reattach() }
        }.store(in: &cancellables)
        sessions.onEvents = { [weak self] in self?.store.dispatch($0) }
        store.start()
        sessions.start()
        UpdateStore.shared.start { [weak self] in self?.settings.checkUpdates ?? false }
        // Once, on the first launch: walk through sign-ins, hooks and notifications.
        if !UserDefaults.standard.bool(forKey: "welcomeShown") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.openWelcome() }
        }
        installDebugCommands()
    }

    /// `scripts/dev-cmd.sh open|close|refresh|hooks-install|hooks-remove` posts these; handy for screenshots and tests.
    private func installDebugCommands() {
        let center = DistributedNotificationCenter.default()
        for (name, action) in [("app.aureole.open", { [weak self] in self?.notch?.setPinnedOpen(true) }),
                               ("app.aureole.close", { [weak self] in self?.notch?.setPinnedOpen(false) }),
                               ("app.aureole.hooks-install", { [weak self] in self?.sessions.installHooks() }),
                               ("app.aureole.hooks-remove", { [weak self] in self?.sessions.uninstallHooks() }),
                               ("app.aureole.statusline-install", { [weak self] in self?.sessions.installStatusline() }),
                               ("app.aureole.statusline-remove", { [weak self] in self?.sessions.uninstallStatusline() }),
                               ("app.aureole.welcome", { [weak self] in self?.openWelcome() }),
                               ("app.aureole.notify-test", { [weak self] in self?.store.sendTest(to: ChannelConfig(kind: .native)) }),
                               ("app.aureole.codex-hooks-install", { [weak self] in self?.sessions.installCodexHooks() }),
                               ("app.aureole.codex-hooks-remove", { [weak self] in self?.sessions.uninstallCodexHooks() }),
                               ("app.aureole.update-dryrun", { Self.updateDryRun() }),
                               ("app.aureole.refresh", { [weak self] in self?.refreshNow() })] as [(String, () -> Void)] {
            center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { action() }
            }
        }
    }

    /// Downloads and verifies the latest release as an update would, without replacing anything.
    private static func updateDryRun() {
        Task.detached {
            guard let r = await UpdateChecker.check(current: "0.0.1"), let dmg = r.dmgURL else {
                AureoleLog.shared.log("update dry run: no release with a dmg"); return
            }
            do {
                let staged = try await Updater.prepare(dmg: dmg, currentApp: Bundle.main.bundlePath, version: r.version) { _ in }
                AureoleLog.shared.log("update dry run: \(r.version) verified, staged at \(staged)")
            } catch {
                AureoleLog.shared.log("update dry run failed: \(error.localizedDescription)")
            }
        }
    }

    private func reattach() {
        notch?.followsPointer = settings.displayChoice == .mouse
        notch?.attach(to: preferredScreen())
    }

    /// The notch screen by default; the menu-bar screen, or the one under the pointer, if the user chose so.
    func preferredScreen() -> NSScreen? {
        switch settings.displayChoice {
        case .notch:
            return NSScreen.screens.first { NotchGeometry.detect(on: $0).hasHardwareNotch } ?? NSScreen.screens.first
        case .main:
            return NSScreen.screens.first
        case .mouse:
            let p = NSEvent.mouseLocation
            return NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.screens.first
        }
    }

    /// Takes out everything Aureole put outside its own folder (hooks, status line, Codex hooks, login item),
    /// then moves its data, logs and the app itself to the Trash, and quits.
    func uninstall() {
        let alert = NSAlert()
        alert.messageText = L10n.t("Uninstall Aureole?")
        alert.informativeText = L10n.t("This removes Aureole's hooks from ~/.claude/settings.json and ~/.codex/hooks.json, puts back the status line you had before, turns off launch at login, moves Aureole's data, logs and the app to the Trash, and quits. Your other hooks and settings are kept.")
        alert.addButton(withTitle: L10n.t("Uninstall"))
        alert.addButton(withTitle: L10n.t("Cancel"))
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        AureoleLog.shared.log("uninstalling")
        sessions.refreshHookStatus()
        if sessions.hookStatus != .notInstalled { sessions.uninstallHooks() }
        if sessions.statuslineInstalled { sessions.uninstallStatusline() }
        if sessions.codexHookStatus != .notInstalled { sessions.uninstallCodexHooks() }
        try? SMAppService.mainApp.unregister()
        let fm = FileManager.default
        for url in [AureolePaths.appSupport, fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Aureole"),
                    URL(fileURLWithPath: Bundle.main.bundlePath)] where fm.fileExists(atPath: url.path) {
            try? fm.trashItem(at: url, resultingItemURL: nil)
        }
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        NSApp.terminate(nil)
    }

    func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: settings, store: store, sessions: sessions,
                                    openWelcome: { [weak self] in self?.openWelcome() },
                                    uninstall: { [weak self] in self?.uninstall() })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Aureole Settings"
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func openWelcome() {
        UserDefaults.standard.set(true, forKey: "welcomeShown")
        if welcomeWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Aureole"
            window.isReleasedWhenClosed = false
            let view = WelcomeView(settings: settings, store: store, sessions: sessions, actions: self,
                                   close: { [weak window] in window?.close() })
            window.contentView = NSHostingView(rootView: view)
            window.center()
            welcomeWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        welcomeWindow?.makeKeyAndOrderFront(nil)
    }

    func refreshNow() { store.refreshAll(force: true) }
    func togglePinned() { notch?.togglePinned() }
    func jump(to session: AgentSession) {
        notch?.setPinnedOpen(false)
        sessions.acknowledge(session)
        sessions.jump(to: session)
    }
    func quit() { NSApp.terminate(nil) }
}
