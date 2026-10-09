import SwiftUI
import ApplicationServices
import AureoleCore

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var store: UsageStore
    @ObservedObject var sessions: SessionStore
    var openWelcome: () -> Void = {}

    var body: some View {
        TabView {
            GeneralTab(settings: settings, openWelcome: openWelcome).tabItem { Label(L10n.t("General"), systemImage: "gearshape") }
            ProvidersTab(settings: settings, store: store).tabItem { Label(L10n.t("Providers"), systemImage: "person.2") }
            SessionsTab(settings: settings, sessions: sessions).tabItem { Label(L10n.t("Sessions"), systemImage: "terminal") }
            ChannelsTab(settings: settings, store: store).tabItem { Label(L10n.t("Notifications"), systemImage: "bell") }
        }
        .frame(minWidth: 560, minHeight: 460)
        .padding(12)
        .id(settings.language)
    }
}

struct GeneralTab: View {
    @ObservedObject var settings: SettingsStore
    var openWelcome: () -> Void = {}

    var body: some View {
        Form {
            Picker(L10n.t("Language"), selection: $settings.language) {
                ForEach(Language.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker(L10n.t("Panel layout"), selection: $settings.panelLayout) {
                ForEach(PanelLayout.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker(L10n.t("Panel background"), selection: $settings.panelStyle) {
                ForEach(PanelStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            if settings.panelStyle == .glass {
                Text(L10n.t("Liquid Glass needs macOS 26; older systems get a frosted material instead."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker(L10n.t("Refresh every (when busy)"), selection: $settings.refreshInterval) {
                Text(L10n.t("30 s")).tag(30.0)
                Text(L10n.t("1 min")).tag(60.0)
                Text(L10n.t("2 min")).tag(120.0)
                Text(L10n.t("5 min")).tag(300.0)
            }
            Text(L10n.t("Slows down to 5 min automatically while nothing changes."))
                .font(.caption).foregroundStyle(.secondary)
            Stepper(L10n.f("Warn at %d%%", settings.thresholdWarn), value: $settings.thresholdWarn, in: 50...94, step: 5)
            Stepper(L10n.f("Critical at %d%%", settings.thresholdCritical), value: $settings.thresholdCritical, in: 80...100, step: 5)
            Toggle(L10n.t("Suggest routing work to the provider with headroom"), isOn: $settings.routingHints)
            Toggle(L10n.t("macOS notifications"), isOn: $settings.nativeNotifications)
            Toggle(L10n.t("Ambient motion (breathing glow, flowing forecast)"), isOn: $settings.ambientMotion)
            Text(L10n.t("Off automatically when macOS is set to reduce motion."))
                .font(.caption).foregroundStyle(.secondary)
            Button(L10n.t("Open the welcome guide…")) { openWelcome() }
            EscapeRow()
            Toggle(L10n.t("Check for new versions once a day"), isOn: $settings.checkUpdates)
            UpdateRow()
            Text(L10n.f("Version %@ · log at %@", AureoleInfo.version, "~/Library/Logs/Aureole/aureole.log"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

struct ProvidersTab: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var store: UsageStore

    var body: some View {
        Form {
            Section("Claude") {
                Toggle(L10n.t("Track Claude (Claude Code sign-in)"), isOn: $settings.claudeEnabled)
                Picker(L10n.t("Read Keychain via"), selection: $settings.claudeCredentialSource) {
                    Text(L10n.t("security CLI (one-time Always Allow)")).tag(ClaudeCredentialSource.securityCLI)
                    Text(L10n.t("Keychain API")).tag(ClaudeCredentialSource.secItem)
                }
                statusLine(.claude)
            }
            Section("Codex") {
                Toggle(L10n.t("Track Codex (~/.codex/auth.json)"), isOn: $settings.codexEnabled)
                statusLine(.codex)
            }
            Section {
                Text(L10n.t("Aureole only reads tokens that Claude Code and Codex CLI already store. It never refreshes or writes them, and it only talks to each vendor's own usage endpoint."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func statusLine(_ id: ProviderID) -> some View {
        let text: String
        switch store.status[id] {
        case .ok?: text = L10n.t("Connected") + (store.snapshots[id]?.planLabel.map { " · \($0)" } ?? "")
        case .loading?: text = L10n.t("Loading…")
        case .rateLimited?: text = L10n.t("Rate limited")
        case .signedOut(let m)?, .error(let m)?: text = m
        default: text = settings.isEnabled(id) ? L10n.t("Waiting…") : L10n.t("Off")
        }
        return LabeledContent(L10n.t("Status")) { Text(text).foregroundStyle(.secondary).textSelection(.enabled) }
    }
}

struct SessionsTab: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var sessions: SessionStore

    var body: some View {
        Form {
            Section {
                Toggle(L10n.t("Track Claude Code sessions"), isOn: $settings.sessionsEnabled)
                LabeledContent(L10n.t("Claude Code hooks")) {
                    HStack(spacing: 10) {
                        Text(statusText).foregroundStyle(.secondary)
                        switch sessions.hookStatus {
                        case .installed: Button(L10n.t("Remove hooks")) { sessions.uninstallHooks() }
                        default: Button(L10n.t("Install hooks")) { sessions.installHooks() }
                        }
                    }
                }
                LabeledContent(L10n.t("Codex hooks")) {
                    HStack(spacing: 10) {
                        Text(L10n.t(sessions.codexHookStatus == .notInstalled ? "Not installed" : "On")).foregroundStyle(.secondary)
                        if sessions.codexHookStatus == .notInstalled {
                            Button(L10n.t("Install")) { sessions.installCodexHooks() }
                        } else {
                            Button(L10n.t("Remove")) { sessions.uninstallCodexHooks() }
                        }
                    }
                }
                Text(L10n.t("Adds the same helper to ~/.codex/hooks.json. Codex asks you to trust it once: the desktop app prompts at startup; in the CLI, run /hooks."))
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent(L10n.t("Usage from the status line")) {
                    HStack(spacing: 10) {
                        Text(L10n.t(sessions.statuslineInstalled ? "On" : "Not installed")).foregroundStyle(.secondary)
                        if sessions.statuslineInstalled {
                            Button(L10n.t("Remove")) { sessions.uninstallStatusline() }
                        } else {
                            Button(L10n.t("Install")) { sessions.installStatusline() }
                        }
                    }
                }
                Text(L10n.t("Claude Code hands its status line the 5-hour and weekly numbers and each session's exact context use. Aureole reads them there, so it asks the usage endpoint far less often. A status line you already have keeps working and is restored on removal."))
                    .font(.caption).foregroundStyle(.secondary)
                if let err = sessions.lastError {
                    Text(err).font(.caption).foregroundStyle(.orange)
                }
                Toggle(L10n.t("Keep an 80-character excerpt of each prompt"), isOn: $settings.sessionPromptPreview)
                Picker(L10n.t("Notify when a session waits"), selection: $settings.notifyWaitingMinutes) {
                    Text(L10n.t("Off")).tag(0)
                    ForEach([1, 2, 5, 10], id: \.self) { Text(L10n.f("after %d min", $0)).tag($0) }
                }
                Toggle(L10n.t("Notify when a task is done"), isOn: $settings.notifyDone)
                Picker(L10n.t("Approve requests from the panel"), selection: $settings.approveFromPanelSeconds) {
                    Text(L10n.t("Off")).tag(0)
                    ForEach([15, 30, 60], id: \.self) { Text(L10n.f("wait up to %d s", $0)).tag($0) }
                }
                .onChange(of: settings.approveFromPanelSeconds) { _, v in if v > 0 { sessions.refreshHookTimeouts() } }
                Text(L10n.t("Hover a waiting session to see the full request and choose Allow once or Deny. Nothing is ever allowed without that click, and there is no \"always allow\". While Aureole waits, the terminal prompt is held back; if you do not answer in time, it appears as usual."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L10n.t("Uses the same channels as usage alerts (macOS notification, WeChat, etc.)."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text(L10n.t("Aureole adds a small helper to ~/.claude/settings.json that runs on each hook event and writes one file per session under Application Support (0600): folder, state, the current tool, and an optional prompt excerpt. Nothing leaves this Mac. Your other hooks are kept."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { sessions.refreshHookStatus() }
    }

    private var statusText: String {
        switch sessions.hookStatus {
        case .installed(let n): return L10n.f("Installed (%d events)", n)
        case .partial(let n): return L10n.f("Partially installed (%d of %d)", n, HookInstaller.events.count)
        case .notInstalled: return L10n.t("Not installed")
        }
    }
}

struct ChannelsTab: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu(L10n.t("Add channel")) {
                    ForEach(ChannelKind.allCases.filter { $0 != .native }) { kind in
                        Button(kind.displayName) { settings.channels.append(ChannelConfig(kind: kind)) }
                    }
                }
                .fixedSize()
                Spacer()
                if let err = store.lastChannelError {
                    Text(err).font(.caption).foregroundStyle(.orange).lineLimit(1)
                }
            }
            if settings.channels.isEmpty {
                Text(L10n.t("Events: warn/critical thresholds, window reset, ‘runs out before reset’ forecast, sign-in lost. Add a channel to receive them outside macOS."))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach($settings.channels) { $channel in
                        ChannelEditor(channel: $channel,
                                      onTest: { store.sendTest(to: channel) },
                                      onDelete: { settings.channels.removeAll { $0.id == channel.id } })
                    }
                }
            }
        }
        .padding(.top, 6)
    }
}

struct ChannelEditor: View {
    @Binding var channel: ChannelConfig
    var onTest: () -> Void
    var onDelete: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Toggle("", isOn: $channel.enabled).labelsHidden()
                    TextField(L10n.t("Name"), text: $channel.name).textFieldStyle(.plain).font(.headline)
                    Spacer()
                    Text(channel.kind.displayName).font(.caption).foregroundStyle(.secondary)
                    Button(L10n.t("Test"), action: onTest)
                    Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                }
                Text(channel.kind.hint).font(.caption).foregroundStyle(.secondary)
                ForEach(channel.kind.fields, id: \.self) { field in
                    switch field {
                    case .url: TextField(channel.kind == .ntfy ? L10n.t("Topic URL") : L10n.t("Webhook URL"), text: $channel.url)
                    case .token: SecureField(channel.kind == .telegram ? L10n.t("Bot token") : L10n.t("Key"), text: $channel.token)
                    case .target: TextField(channel.kind == .shell ? L10n.t("Script path") : L10n.t("Chat id"), text: $channel.target)
                    case .headers: TextField(L10n.t("Extra headers (Key: Value; Key2: Value2)"), text: headersBinding)
                    case .body: TextField(L10n.t("JSON body template"), text: $channel.bodyTemplate, axis: .vertical).lineLimit(2...4)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    private var headersBinding: Binding<String> {
        Binding(
            get: { channel.headers.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "; ") },
            set: { text in
                var out: [String: String] = [:]
                for pair in text.split(separator: ";") {
                    let kv = pair.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if kv.count == 2, !kv[0].isEmpty { out[kv[0]] = kv[1] }
                }
                channel.headers = out
            }
        )
    }
}

/// "Up to date" / "New version 0.3.1 · Download", with a manual check.
struct UpdateRow: View {
    @ObservedObject var updates = UpdateStore.shared

    var body: some View {
        HStack {
            if let r = updates.available {
                Text(L10n.f("Version %@ is available", r.version)).foregroundStyle(.orange)
                Button(L10n.t("Download")) { updates.openRelease() }
            } else {
                Text(L10n.t(updates.checking ? "Checking…" : "No newer version found")).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L10n.t("Check now")) { updates.check(force: true) }.disabled(updates.checking)
        }
    }
}

/// Esc to close the panel needs Accessibility, so it is offered, never asked for unprompted.
struct EscapeRow: View {
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        LabeledContent(L10n.t("Esc closes the panel")) {
            HStack(spacing: 10) {
                Text(L10n.t(trusted ? "On" : "Needs Accessibility")).foregroundStyle(.secondary)
                if !trusted {
                    Button(L10n.t("Allow…")) {
                        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                        trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
                    }
                }
            }
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in trusted = AXIsProcessTrusted() }
    }
}

