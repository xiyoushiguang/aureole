import Foundation
import AureoleCore

/// How the app was started. `--demo` shows sample data (handy without any agent installed, and for trying the
/// app out); `--snapshot <dir> [--lang en|zh]` renders the panel with that data to PNG files and quits;
/// `--film <dir> [--scene journey|compare] [--lang en|zh]` renders it frame by frame with the sky in motion.
enum LaunchMode {
    case normal
    case demo
    case snapshot(dir: URL, language: Language)
    case film(dir: URL, scene: String, language: Language)

    static var current: LaunchMode { parse(CommandLine.arguments) }

    static func parse(_ args: [String]) -> LaunchMode {
        if let i = args.firstIndex(of: "--film"), i + 1 < args.count {
            var language = Language.english
            if let j = args.firstIndex(of: "--lang"), j + 1 < args.count, args[j + 1].hasPrefix("zh") { language = .chineseSimplified }
            var scene = "journey"
            if let j = args.firstIndex(of: "--scene"), j + 1 < args.count { scene = args[j + 1] }
            return .film(dir: URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath), scene: scene, language: language)
        }
        if let i = args.firstIndex(of: "--snapshot") {
            let dir = i + 1 < args.count && !args[i + 1].hasPrefix("-") ? args[i + 1] : "build/snapshots"
            var language = Language.english
            if let j = args.firstIndex(of: "--lang"), j + 1 < args.count, args[j + 1].hasPrefix("zh") { language = .chineseSimplified }
            return .snapshot(dir: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath), language: language)
        }
        return args.contains("--demo") ? .demo : .normal
    }

    var isDemo: Bool {
        switch self {
        case .normal: return false
        case .demo, .snapshot, .film: return true
        }
    }

    /// A scratch settings domain, emptied each time, so a demo starts from defaults and never touches real settings.
    static func demoDefaults() -> UserDefaults {
        let name = "app.aureole.demo"
        UserDefaults.standard.removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name) ?? .standard
    }
}
