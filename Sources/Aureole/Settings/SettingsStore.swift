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
