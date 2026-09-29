import AppKit
import SwiftUI
import AureoleCore

@MainActor
protocol AppActions: AnyObject {
    func openSettings()
    func refreshNow()
    func togglePinned()
    func quit()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, AppActions {
    let settings = SettingsStore()
    private(set) lazy var store = UsageStore(settings: settings)
    private var notch: NotchController?
    private var statusItem: StatusItemController?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AureoleLog.shared.log("Aureole \(AureoleInfo.version) launched")
        statusItem = StatusItemController(store: store, settings: settings, actions: self)
        let controller = NotchController(store: store, settings: settings, actions: self)
        controller.attach(to: Self.preferredScreen())
        notch = controller
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.notch?.attach(to: Self.preferredScreen()) }
        }
        store.start()
        installDebugCommands()
    }

    /// `scripts/dev-cmd.sh open|close|refresh` posts these; handy for screenshots and tests.
    private func installDebugCommands() {
        let center = DistributedNotificationCenter.default()
        for (name, action) in [("app.aureole.open", { [weak self] in self?.notch?.setPinnedOpen(true) }),
                               ("app.aureole.close", { [weak self] in self?.notch?.setPinnedOpen(false) }),
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
            let view = SettingsView(settings: settings, store: store)
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

    func refreshNow() { store.refreshAll(force: true) }
    func togglePinned() { notch?.togglePinned() }
    func quit() { NSApp.terminate(nil) }
}
