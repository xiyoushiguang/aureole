import SwiftUI
import ServiceManagement
import UserNotifications
import AureoleCore

/// The one button a guide step offers.
struct StepAction {
    let label: String
    let run: () -> Void
}

/// First-launch guide: each thing Aureole needs, whether it is done, and one button to do it.
struct WelcomeView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var store: UsageStore
    @ObservedObject var sessions: SessionStore
    weak var actions: AppActions?
    let close: () -> Void
    @State private var notifications: UNAuthorizationStatus = .notDetermined
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @ObservedObject private var scanner = AgentScanner.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("Welcome to Aureole")).font(.title2.bold())
                    Text(L10n.t("Your quotas and Claude Code sessions live in the notch. Hover it to open the panel."))
                        .foregroundStyle(.secondary)
                }
            }
            detected
            VStack(spacing: 0) {
                step(done: providerOK(.claude), title: L10n.t("Claude usage"),
                     detail: providerDetail(.claude, signIn: "claude login"),
                     button: providerOK(.claude) ? nil : StepAction(label: L10n.t("Retry"), run: { actions?.refreshNow() }))
                Divider()
                step(done: providerOK(.codex), optional: true, title: L10n.t("Codex usage"),
                     detail: providerDetail(.codex, signIn: "codex login"),
                     button: providerOK(.codex) ? nil : StepAction(label: L10n.t("Retry"), run: { actions?.refreshNow() }))
                Divider()
                step(done: sessions.hookStatus != .notInstalled, title: L10n.t("Track Claude Code sessions"),
                     detail: L10n.t("Adds a small helper to ~/.claude/settings.json so each session's state shows up. Your other hooks are kept."),
                     button: sessions.hookStatus == .notInstalled ? StepAction(label: L10n.t("Install hooks"), run: { sessions.installHooks() }) : nil)
                Divider()
                step(done: sessions.codexHookStatus != .notInstalled, optional: scanner.findings[.codex]?.installed != true,
                     title: L10n.t("Track Codex sessions"),
                     detail: L10n.t("Adds the same helper to ~/.codex/hooks.json. Codex asks you to trust it once: the desktop app prompts at startup; in the CLI, run /hooks."),
                     button: sessions.codexHookStatus == .notInstalled ? StepAction(label: L10n.t("Install hooks"), run: { sessions.installCodexHooks() }) : nil)
                Divider()
                step(done: sessions.statuslineInstalled, optional: true, title: L10n.t("Usage from the status line"),
                     detail: L10n.t("Fresher numbers, exact context use, far fewer calls to the usage endpoint. Keeps any status line you already have."),
                     button: sessions.statuslineInstalled ? nil : StepAction(label: L10n.t("Install"), run: { sessions.installStatusline() }))
                Divider()
                step(done: notifications == .authorized, title: L10n.t("Notifications"),
                     detail: L10n.t("So a session waiting on you, or a finished task, can reach you. Phone and chat channels are in Settings → Notifications."),
                     button: notifications == .authorized ? nil : StepAction(label: L10n.t("Send a test"), run: { sendTest() }))
                Divider()
                step(done: launchAtLogin, optional: true, title: L10n.t("Launch at login"),
                     detail: L10n.t("Keep the notch lit after a restart."),
                     button: launchAtLogin ? nil : StepAction(label: L10n.t("Turn on"), run: { toggleLogin() }))
            }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            HStack {
                Text(L10n.t("You can open this guide again from Settings → General."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.t("Done")) { close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .task {
            if !scanner.scanned { scanner.scan() }
            await refreshNotificationStatus()
        }
    }

    /// What the scan found: each agent, and whether it runs in a terminal or a desktop app.
    private var detected: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.t("Detected on this Mac")).font(.headline)
                Spacer()
                if scanner.scanning { ProgressView().controlSize(.small) }
                Button(L10n.t("Scan again")) { scanner.scan() }.disabled(scanner.scanning)
            }
            ForEach([ProviderID.claude, .codex], id: \.self) { p in
                if let f = scanner.findings[p] { finding(f) }
            }
            if scanner.scanned, !scanner.findings.values.contains(where: \.installed) {
                Text(L10n.t("No Claude Code or Codex found. Install one, then scan again."))
                    .font(.callout).foregroundStyle(.orange)
            }
            ForEach(scanner.terminalsNeedingSetup, id: \.self) { id in
                Text(id == "net.kovidgoyal.kitty"
                     ? L10n.t("kitty: to jump to a window, set allow_remote_control and listen_on in kitty.conf.")
                     : L10n.t("Ghostty: tab jumps need Ghostty 1.3 or later; macOS asks once to let Aureole control it."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func finding(_ f: AgentFinding) -> some View {
        let name = f.provider == .claude ? "Claude Code" : "Codex"
        var places: [String] = []
        if !f.runningIn.isEmpty {
            places.append(L10n.f("running in %@", f.runningIn.map(AppNames.name).joined(separator: ", ")))
        } else {
            if f.cliPath != nil { places.append(L10n.t("command line")) }
            places += f.desktopApps.map { L10n.f("%@ desktop app", AppNames.name($0)) }
        }
        var hints: [String] = []
        if f.usesTerminal { hints.append(L10n.t("In a terminal: a click jumps to the session's tab.")) }
        if f.usesDesktop { hints.append(L10n.t("In a desktop app: a click brings the app forward (it cannot open a specific conversation).")) }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: f.installed ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(f.installed ? .green : .secondary).font(.system(size: 15))
            VStack(alignment: .leading, spacing: 2) {
                Text(name + " · " + (f.installed ? places.joined(separator: " · ") : L10n.t("not found")))
                    .font(.callout.weight(.medium))
                ForEach(hints, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder
    private func step(done: Bool, optional: Bool = false, title: String, detail: String,
                      button: StepAction?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : (optional ? "circle.dashed" : "circle"))
                .foregroundStyle(done ? .green : .secondary)
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.body.weight(.semibold))
                    if optional && !done { Text(L10n.t("optional")).font(.caption).foregroundStyle(.secondary) }
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let button {
                Button(button.label, action: button.run)
            }
        }
        .padding(.vertical, 10)
    }

    private func providerOK(_ id: ProviderID) -> Bool {
        if case .ok? = store.status[id] { return true }
        return store.snapshots[id] != nil && store.status[id]?.message == nil
    }

    private func providerDetail(_ id: ProviderID, signIn: String) -> String {
        if providerOK(id), let w = store.snapshots[id]?.primary {
            return L10n.f("Connected · %@ used %d%%", w.displayLabel, Int(w.usedPercent.rounded()))
        }
        var text = L10n.f("Sign in with `%@` in a terminal, then retry.", signIn)
        if id == .claude {
            text += " " + L10n.t("macOS will ask once whether Aureole may read the Claude Code Keychain item: choose Always Allow.")
        }
        if let m = store.status[id]?.message { text += "\n" + m }
        return text
    }

    private func sendTest() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { await refreshNotificationStatus() }
        }
        if let native = settings.channels.first(where: { $0.kind == .native }) {
            store.sendTest(to: native)
        } else {
            store.sendTest(to: ChannelConfig(kind: .native))
        }
    }

    private func refreshNotificationStatus() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        await MainActor.run { notifications = status }
    }

    private func toggleLogin() {
        try? SMAppService.mainApp.register()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
