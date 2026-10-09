import Foundation
import Combine
import AureoleCore

enum PanelStyle: String, Codable, CaseIterable {
    case solid, glass

    var displayName: String {
        switch self {
        case .solid: return L10n.t("Solid black")
        case .glass: return L10n.t("Liquid Glass")
        }
    }
}

/// What the open panel looks like: the horizon with a lane per session, or plain rows and a task list.
enum PanelLayout: String, Codable, CaseIterable {
    case horizon, list

    var displayName: String {
        switch self {
        case .horizon: return L10n.t("Horizon")
        case .list: return L10n.t("List")
        }
    }
}

/// Which screen the panel hangs from.
enum DisplayChoice: String, Codable, CaseIterable {
    /// The built-in screen with the notch; the main screen when the lid is closed or there is no notch.
    case notch
    /// The screen with the menu bar (System Settings → Displays → "main display").
    case main
    /// Whichever screen the pointer is on.
    case mouse

    var displayName: String {
        switch self {
        case .notch: return L10n.t("Notch screen")
        case .main: return L10n.t("Main display")
        case .mouse: return L10n.t("Screen with the pointer")
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard
    private let channelsURL = AureolePaths.appSupport.appendingPathComponent("channels.json")

    @Published var refreshInterval: TimeInterval { didSet { defaults.set(refreshInterval, forKey: "refreshInterval") } }
    @Published var thresholdWarn: Int { didSet { defaults.set(thresholdWarn, forKey: "thresholdWarn") } }
    @Published var thresholdCritical: Int { didSet { defaults.set(thresholdCritical, forKey: "thresholdCritical") } }
    @Published var claudeEnabled: Bool { didSet { defaults.set(claudeEnabled, forKey: "claudeEnabled") } }
    @Published var codexEnabled: Bool { didSet { defaults.set(codexEnabled, forKey: "codexEnabled") } }
    @Published var routingHints: Bool { didSet { defaults.set(routingHints, forKey: "routingHints") } }
    @Published var nativeNotifications: Bool { didSet { defaults.set(nativeNotifications, forKey: "nativeNotifications") } }
    @Published var panelStyle: PanelStyle { didSet { defaults.set(panelStyle.rawValue, forKey: "panelStyle") } }
    @Published var panelLayout: PanelLayout { didSet { defaults.set(panelLayout.rawValue, forKey: "panelLayout") } }
    /// Minutes a session may wait on you before a notification goes out; 0 turns it off.
    @Published var notifyWaitingMinutes: Int { didSet { defaults.set(notifyWaitingMinutes, forKey: "notifyWaitingMinutes") } }
    @Published var notifyDone: Bool { didSet { defaults.set(notifyDone, forKey: "notifyDone") } }
    /// Ask GitHub once a day whether a newer release is out.
    @Published var checkUpdates: Bool { didSet { defaults.set(checkUpdates, forKey: "checkUpdates") } }
    /// Seconds a permission request waits for a click in the panel before the terminal asks; 0 = off.
    /// Stored where the hook helper reads it.
    @Published var approveFromPanelSeconds: Int { didSet { defaults.set(approveFromPanelSeconds, forKey: ApprovalFiles.waitKey) } }
    /// The slow breathing glow and flowing forecast. They make the window server redraw the panel continuously.
    @Published var ambientMotion: Bool { didSet { defaults.set(ambientMotion, forKey: "ambientMotion") } }
    @Published var displayChoice: DisplayChoice { didSet { defaults.set(displayChoice.rawValue, forKey: "displayChoice") } }
    /// No pushes (macOS or channels) in these hours; the panel still shows everything.
    @Published var quietHoursEnabled: Bool { didSet { defaults.set(quietHoursEnabled, forKey: "quietHoursEnabled") } }
    /// Minutes after midnight.
    @Published var quietStart: Int { didSet { defaults.set(quietStart, forKey: "quietStart") } }
    @Published var quietEnd: Int { didSet { defaults.set(quietEnd, forKey: "quietEnd") } }
    var quietHours: QuietHours? { quietHoursEnabled ? QuietHours(start: quietStart, end: quietEnd) : nil }
    @Published var sessionsEnabled: Bool { didSet { defaults.set(sessionsEnabled, forKey: "sessionsEnabled") } }
    /// The hook helper reads this key too (via the app's defaults domain) to decide whether to keep a prompt excerpt.
    @Published var sessionPromptPreview: Bool { didSet { defaults.set(sessionPromptPreview, forKey: "sessionPromptPreview") } }
    @Published var language: Language {
        didSet { defaults.set(language.rawValue, forKey: "language"); L10n.language = language }
    }
    @Published var claudeCredentialSource: ClaudeCredentialSource {
        didSet { defaults.set(claudeCredentialSource.rawValue, forKey: "claudeCredentialSource") }
    }
    /// Webhook URLs and tokens live here, in a 0600 file under Application Support, never in UserDefaults.
    @Published var channels: [ChannelConfig] { didSet { saveChannels() } }

    init() {
        let d = UserDefaults.standard
        refreshInterval = d.object(forKey: "refreshInterval") as? TimeInterval ?? 60
        thresholdWarn = d.object(forKey: "thresholdWarn") as? Int ?? 80
        thresholdCritical = d.object(forKey: "thresholdCritical") as? Int ?? 95
        claudeEnabled = d.object(forKey: "claudeEnabled") as? Bool ?? true
        codexEnabled = d.object(forKey: "codexEnabled") as? Bool ?? true
        routingHints = d.object(forKey: "routingHints") as? Bool ?? true
        nativeNotifications = d.object(forKey: "nativeNotifications") as? Bool ?? true
        claudeCredentialSource = ClaudeCredentialSource(rawValue: d.string(forKey: "claudeCredentialSource") ?? "") ?? .securityCLI
        language = Language(rawValue: d.string(forKey: "language") ?? "") ?? .system
        panelStyle = PanelStyle(rawValue: d.string(forKey: "panelStyle") ?? "") ?? .solid
        panelLayout = PanelLayout(rawValue: d.string(forKey: "panelLayout") ?? "") ?? .horizon
        notifyWaitingMinutes = d.object(forKey: "notifyWaitingMinutes") as? Int ?? 2
        notifyDone = d.object(forKey: "notifyDone") as? Bool ?? true
        checkUpdates = d.object(forKey: "checkUpdates") as? Bool ?? true
        approveFromPanelSeconds = d.object(forKey: ApprovalFiles.waitKey) as? Int ?? 0
        ambientMotion = d.object(forKey: "ambientMotion") as? Bool ?? true
        sessionsEnabled = d.object(forKey: "sessionsEnabled") as? Bool ?? true
        displayChoice = DisplayChoice(rawValue: d.string(forKey: "displayChoice") ?? "") ?? .notch
        quietHoursEnabled = d.object(forKey: "quietHoursEnabled") as? Bool ?? false
        quietStart = d.object(forKey: "quietStart") as? Int ?? 0
        quietEnd = d.object(forKey: "quietEnd") as? Int ?? 8 * 60
        sessionPromptPreview = d.object(forKey: "sessionPromptPreview") as? Bool ?? true
        if let data = try? Data(contentsOf: channelsURL),
           let decoded = try? JSONDecoder.aureole.decode([ChannelConfig].self, from: data) {
            channels = decoded
        } else {
            channels = []
        }
        L10n.language = language
    }

    func isEnabled(_ id: ProviderID) -> Bool {
        switch id {
        case .claude: return claudeEnabled
        case .codex: return codexEnabled
        }
    }

    private func saveChannels() {
        guard let data = try? JSONEncoder.aureole.encode(channels) else { return }
        try? data.write(to: channelsURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: channelsURL.path)
    }
}
