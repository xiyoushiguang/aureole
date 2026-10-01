import Foundation

public enum Language: String, Codable, CaseIterable, Sendable {
    case system, english, chineseSimplified

    public var displayName: String {
        switch self {
        case .system: return L10n.t("System")
        case .english: return "English"
        case .chineseSimplified: return "简体中文"
        }
    }
}

/// Tiny in-process string table. English strings are the keys; add a language by adding a table.
public enum L10n {
    public static var language: Language = .system

    /// "en" or "zh".
    public static var effective: String {
        switch language {
        case .english: return "en"
        case .chineseSimplified: return "zh"
        case .system:
            let first = Locale.preferredLanguages.first ?? "en"
            return first.hasPrefix("zh") ? "zh" : "en"
        }
    }

    public static var locale: Locale { effective == "zh" ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US") }

    public static func t(_ key: String) -> String {
        effective == "zh" ? (zh[key] ?? key) : key
    }

    public static func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), locale: locale, arguments: args)
    }

    static let zh: [String: String] = [
        // windows & time
        "5h": "5小时", "Week": "本周", "%@ wk": "%@ 本周", "%@ 5h": "%@ 5小时", "Extra": "额外用量",
        "now": "现在", "<1m": "<1分", "%dm": "%d分", "%dh": "%d小时", "%dh %dm": "%d小时%d分",
        "%dd": "%d天", "%dd %dh": "%d天%d小时",
        "just now": "刚刚", "%@ ago": "%@前",
        // events
        "%@ %@ window at %d%%": "%@ %@额度已用 %d%%",
        "%@ %@ window reset": "%@ %@额度已重置",
        "%@ %@ will run out before reset": "%@ %@额度会在重置前用完",
        "%@ sign-in needed": "%@ 需要重新登录",
        "Used %d%%": "已用 %d%%", ", resets %@": "，%@ 重置",
        "Fresh window": "新窗口已开始", ", next reset %@": "，下次重置 %@",
        "At the current pace it hits 100%% around %@": "按当前速度约在 %@ 用完", ", reset is %@": "，重置时间 %@",
        // panel
        "route new work → %@": "新任务转给 %@", "Refresh": "刷新", "Settings…": "设置…", "Pin": "固定", "Unpin": "取消固定",
        "Loading…": "加载中…", "No windows reported": "未返回额度窗口", "idle": "空闲",
        "≈%d%%/h": "≈%d%%/小时", " · empty %@, before reset": " · %@ 用完，早于重置", " · empty %@": " · %@ 用完",
        // sessions
        "Waiting for you %d": "等你 %d", "Needs you %d": "等你处理 %d", "Working %d": "干活中 %d", "Idle %d": "空闲 %d",
        "Sessions %d": "会话 %d", "context %@": "上下文 %@",
        "approval": "等批准", "question": "在提问", "waited %@": "已等 %@", "thinking": "思考中",
        // horizon
        "%@ used %d%%": "%@已用 %d%%", "Used up": "已用完", "Resets %@": "%@ 后重置",
        "Runs out %@": "%@ 用完", "%@ before the %@ reset": "比 %2$@ 重置早 %1$@", "Lasts until the %@ reset": "够用到 %@ 重置",
        "5-hour": "5 小时", "weekly": "本周", "Now %@": "现在 %@", "%@ start": "%@ 开始", "%@ reset": "%@ 重置",
        "No quota here, about %@": "这段没有额度，约 %@", "Steady pace": "匀速用完的线",
        "Claude working": "Claude 在干活", "Codex working": "Codex 在干活", "Waiting on you": "在等你",
        "Small ring = context used": "小环是上下文占用", "context %d%%": "上下文 %d%%", "Context": "上下文",
        "Panel layout": "面板样式", "Horizon": "晨昏线", "Classic bars": "经典进度条",
        "Context %% is an estimate (200k or 1M window).": "上下文百分比是估算（按 20 万或 100 万窗口）。",
        "Workbench ›": "工作台 ›", "‹ Collapse": "‹ 收起", "Click outside to collapse": "点面板外收回",
        "Jump to terminal": "跳到终端", "Requesting": "正在请求", "Last": "最近", "Prompt": "提示词", "Folder": "目录",
        "No agent sessions right now.": "现在没有正在运行的会话。",
        "Install the Claude Code hooks in Settings → Sessions to see them here.": "在 设置 → 会话 里安装 Claude Code hooks 后，这里会显示会话。",
        "Sessions": "会话", "Track Claude Code sessions": "跟踪 Claude Code 会话", "Claude Code hooks": "Claude Code hooks",
        "Installed (%d events)": "已安装（%d 个事件）", "Partially installed (%d of %d)": "部分安装（%d/%d）", "Not installed": "未安装",
        "Install hooks": "安装 hooks", "Remove hooks": "移除 hooks", "Keep an 80-character excerpt of each prompt": "保留每条提示词的前 80 个字符",
        "Aureole adds a small helper to ~/.claude/settings.json that runs on each hook event and writes one file per session under Application Support (0600): folder, state, the current tool, and an optional prompt excerpt. Nothing leaves this Mac. Your other hooks are kept.":
            "Aureole 会在 ~/.claude/settings.json 里登记一个小程序，每个 hook 事件触发时把该会话的状态写进「应用程序支持」目录下的一个文件（权限 0600）：目录、状态、当前工具，以及可选的提示词摘录。数据不离开这台 Mac，你原有的 hooks 原样保留。",
        // menu
        "Show panel": "显示面板", "Refresh now": "立即刷新", "Launch at login": "开机自启", "Quit Aureole": "退出 Aureole",
        // settings
        "General": "通用", "Providers": "服务商", "Notifications": "通知", "Language": "语言", "System": "跟随系统",
        "Panel background": "面板背景", "Solid black": "纯黑", "Liquid Glass": "液态玻璃",
        "Liquid Glass needs macOS 26; older systems get a frosted material instead.": "液态玻璃需要 macOS 26，旧系统自动改用毛玻璃。",
        "Refresh every (when busy)": "刷新间隔（活跃时）", "Slows down to 5 min automatically while nothing changes.": "数据没有变化时自动放慢到 5 分钟。",
        "Rate limited, retrying in %@": "接口限流，%@ 后重试", "Rate limited": "接口限流中", "30 s": "30 秒", "1 min": "1 分钟", "2 min": "2 分钟", "5 min": "5 分钟",
        "Warn at %d%%": "预警阈值 %d%%", "Critical at %d%%": "严重阈值 %d%%",
        "Suggest routing work to the provider with headroom": "一家快用完时提示把新任务转给另一家",
        "macOS notifications": "macOS 系统通知", "Version %@ · log at %@": "版本 %@ · 日志 %@",
        "Track Claude (Claude Code sign-in)": "跟踪 Claude（复用 Claude Code 的登录）",
        "Read Keychain via": "钥匙串读取方式", "security CLI (one-time Always Allow)": "security 命令（授权一次永久有效）",
        "Keychain API": "钥匙串 API", "Track Codex (~/.codex/auth.json)": "跟踪 Codex（复用 ~/.codex/auth.json）",
        "Status": "状态", "Connected": "已连接", "Waiting…": "等待中…", "Off": "已关闭",
        "Aureole only reads tokens that Claude Code and Codex CLI already store. It never refreshes or writes them, and it only talks to each vendor's own usage endpoint.":
            "Aureole 只读取 Claude Code 与 Codex CLI 已经保存的登录令牌，绝不刷新或改写，也只访问各家官方的用量接口。",
        "Add channel": "添加渠道", "Test": "测试", "Name": "名称",
        "Events: warn/critical thresholds, window reset, ‘runs out before reset’ forecast, sign-in lost. Add a channel to receive them outside macOS.":
            "事件：预警/严重阈值、窗口重置、「重置前用完」预测、登录失效。添加渠道即可在 macOS 之外收到提醒。",
        "Webhook URL": "Webhook 地址", "Topic URL": "主题地址", "Bot token": "机器人 Token", "Key": "密钥",
        "Chat id": "会话 ID", "Script path": "脚本路径",
        "Extra headers (Key: Value; Key2: Value2)": "额外请求头（Key: Value; Key2: Value2）", "JSON body template": "JSON 请求体模板",
        // channels
        "macOS Notification": "macOS 系统通知", "Feishu / Lark": "飞书 / Lark", "DingTalk": "钉钉", "WeCom": "企业微信",
        "ServerChan (WeChat)": "Server酱（微信）", "Custom webhook": "自定义 Webhook", "Shell script": "Shell 脚本",
        "Uses Notification Center. Allow notifications when macOS asks.": "使用通知中心，macOS 询问时请允许。",
        "Channel settings → Integrations → Webhooks → copy URL.": "频道设置 → 整合 → Webhook → 复制地址。",
        "Incoming Webhook URL from api.slack.com/apps.": "在 api.slack.com/apps 创建 Incoming Webhook 并复制地址。",
        "Bot token from @BotFather and your chat id (message @userinfobot).": "向 @BotFather 申请机器人 Token，向 @userinfobot 获取你的会话 ID。",
        "Group → Settings → Bots → Custom bot → webhook URL.": "群设置 → 群机器人 → 添加自定义机器人 → 复制 Webhook 地址。",
        "Group robot webhook URL (security setting: custom keyword ‘Aureole’).": "群机器人 Webhook 地址（安全设置选「自定义关键词」填 Aureole）。",
        "Group robot webhook URL.": "群机器人 Webhook 地址。",
        "Topic URL, e.g. https://ntfy.sh/my-aureole.": "主题地址，例如 https://ntfy.sh/my-aureole。",
        "Server URL (default https://api.day.app) and your device key.": "服务器地址（默认 https://api.day.app）和你的设备密钥。",
        "SendKey from sct.ftqq.com; delivers to WeChat.": "在 sct.ftqq.com 获取 SendKey，消息推送到微信。",
        "POST with a JSON template. Placeholders: {{title}} {{body}} {{event}} {{provider}} {{percent}}.": "以 JSON 模板 POST。占位符：{{title}} {{body}} {{event}} {{provider}} {{percent}}。",
        "Path to an executable. Receives AUREOLE_* env vars and a JSON event on stdin.": "可执行文件路径。通过 AUREOLE_* 环境变量和 stdin 上的 JSON 接收事件。",
        // provider errors
        "No Claude Code sign-in found. Run `claude` and log in first.": "没有找到 Claude Code 的登录，请先运行 `claude` 登录。",
        "Claude token was rejected (%d). Run `claude` once to refresh your sign-in.": "Claude 令牌被拒绝（%d），运行一次 `claude` 刷新登录即可。",
        "Codex token was rejected (%d). Run `codex` once to refresh your sign-in.": "Codex 令牌被拒绝（%d），运行一次 `codex` 刷新登录即可。",
        "No Codex sign-in found (%@ missing). Run `codex` and log in first.": "没有找到 Codex 的登录（缺少 %@），请先运行 `codex` 登录。",
        "Codex auth.json has no access token. Run `codex login`.": "Codex 的 auth.json 里没有访问令牌，请运行 `codex login`。",
        "Codex is using an API key; subscription usage windows need a ChatGPT sign-in (`codex login`).": "Codex 当前用的是 API Key；订阅额度需要 ChatGPT 登录（`codex login`）。",
        "Usage endpoint is rate limiting; backing off": "用量接口限流，稍后重试",
        "Keychain read denied or failed (exit %d). %@": "钥匙串读取被拒绝或失败（退出码 %d）。%@",
    ]
}
