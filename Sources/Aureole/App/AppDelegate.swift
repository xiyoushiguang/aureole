import AppKit
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        AureoleLog.shared.log("Aureole \(AureoleInfo.version) launched")
        statusItem = StatusItemController(store: store, settings: settings, actions: self)
        let controller = NotchController(store: store, sessions: sessions, settings: settings, actions: self)
        controller.attach(to: Self.preferredScreen())
        notch = controller
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.notch?.attach(to: Self.preferredScreen()) }
        }
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
                               ("app.aureole.refresh", { [weak self] in self?.refreshNow() })] as [(String, () -> Void)] {
            center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { action() }
            }
        }
    }

    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { NotchGeometry.detect(on: $0).hasHardwareNotch } ?? NSScreen.main ?? NSScreen.screens.first
    }

    func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: settings, store: store, sessions: sessions,
                                    openWelcome: { [weak self] in self?.openWelcome() })
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
