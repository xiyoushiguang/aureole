import AppKit
import Combine
import ServiceManagement
import AureoleCore

@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store: UsageStore
    private let settings: SettingsStore
    private weak var actions: AppActions?
    private var cancellables: Set<AnyCancellable> = []
    private var launchAtLoginItem: NSMenuItem?

    init(store: UsageStore, settings: SettingsStore, actions: AppActions) {
        self.store = store
        self.settings = settings
        self.actions = actions
        super.init()
        buildMenu()
        update()
        store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.update() }
        }.store(in: &cancellables)
        settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.buildMenu(); self?.update() }
        }.store(in: &cancellables)
        UpdateStore.shared.$available.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.buildMenu() }
        }.store(in: &cancellables)
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: L10n.t("Show panel"), action: #selector(togglePinned), keyEquivalent: "").target = self
        menu.addItem(withTitle: L10n.t("Refresh now"), action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        let login = NSMenuItem(title: L10n.t("Launch at login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        launchAtLoginItem = login
        menu.addItem(login)
        menu.addItem(withTitle: L10n.t("Settings…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        if let r = UpdateStore.shared.available {
            menu.addItem(withTitle: L10n.f("Download version %@…", r.version), action: #selector(openUpdate), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.t("Quit Aureole"), action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        item.button?.imagePosition = .imageLeading
        item.button?.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "Aureole")
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
    }

    private func update() {
        let parts = ProviderID.allCases.compactMap { id -> String? in
            guard settings.isEnabled(id) else { return nil }
            if let s = store.snapshots[id]?.primary { return "\(Int(s.usedPercent.rounded()))" }
            if let st = store.status[id], st.message != nil { return "!" }
            return "–"
        }
        item.button?.title = parts.isEmpty ? "" : " " + parts.joined(separator: "·")
        launchAtLoginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func togglePinned() { actions?.togglePinned() }
    @objc private func refresh() { actions?.refreshNow() }
    @objc private func openSettings() { actions?.openSettings() }
    @objc private func quit() { actions?.quit() }
    @objc private func openUpdate() { UpdateStore.shared.openRelease() }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            AureoleLog.shared.log("launch at login failed: \(error.localizedDescription)")
        }
        update()
    }
}
