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
        "Claude working": "Claude 在干活", "Codex working": "Codex 在干活", "%@ working": "%@ 在干活", "Waiting on you": "在等你",
        "Small ring = context used": "小环是上下文占用", "context %d%%": "上下文 %d%%", "Context": "上下文",
        "%@ needs your approval": "%@ 待你批准", "%@ has a question for you": "%@ 待你回答", "%@ is done": "%@ 已完成", "Finished after %@": "用时 %@",
        "Done %d": "完成 %d", "done": "完成", "done · unseen": "完成·未查看",
        "Waiting %d": "等你 %d", "Notify when a session waits": "会话等你时通知", "after %d min": "等 %d 分钟后",
        "Notify when a task is done": "任务干完时通知",
        "Uses the same channels as usage alerts (macOS notification, WeChat, etc.).": "和额度提醒走同样的渠道（macOS 通知、微信等）。",
        "≈%d%%/day": "≈%d%%/天", "runs out %@": "%@ 用完", "lasts": "够用",
        "Usage from the status line": "从状态栏读取额度", "On": "已开启", "Install": "安装", "Remove": "移除",
        "Claude Code hands its status line the 5-hour and weekly numbers and each session's exact context use. Aureole reads them there, so it asks the usage endpoint far less often. A status line you already have keeps working and is restored on removal.":
            "Claude Code 会把 5 小时、本周额度和每个会话的准确上下文占用交给状态栏。Aureole 从那里读取，就能少调用额度接口。你原有的状态栏照常显示，移除时原样恢复。",
        "quiet %@": "%@无动静", "context %d%% · nearly full": "上下文 %d%% · 快满了",
        "No events for a while. A long build or test is normal; otherwise take a look.": "有一阵没有动静了。如果在跑长时间的编译或测试是正常的，否则去看一眼。",
        "Claude Code will compact the conversation soon.": "Claude Code 快要自动压缩上下文了。",
        "New version %@ ›": "新版本 %@ ›", "Check for new versions once a day": "每天检查一次新版本",
        "Version %@ is available": "%@ 版已发布", "Download": "下载", "Checking…": "正在检查…",
        "No newer version found": "已是最新版本", "Check now": "立即检查", "Download version %@…": "下载 %@ 版…",
        "Welcome to Aureole": "欢迎使用 Aureole",
        "Your quotas and Claude Code sessions live in the notch. Hover it to open the panel.": "额度和 Claude Code 会话都在刘海里。鼠标移到刘海上就能打开面板。",
        "Claude usage": "Claude 额度", "Codex usage": "Codex 额度", "Retry": "重试", "optional": "可选",
        "Adds a small helper to ~/.claude/settings.json so each session's state shows up. Your other hooks are kept.": "在 ~/.claude/settings.json 里登记一个小程序，让每个会话的状态显示出来。你原有的 hooks 保留不动。",
        "Fresher numbers, exact context use, far fewer calls to the usage endpoint. Keeps any status line you already have.": "数字更及时、上下文占用更准，额度接口调用少得多。你原有的状态栏照常显示。",
        "So a session waiting on you, or a finished task, can reach you. Phone and chat channels are in Settings → Notifications.": "会话等你、任务干完时能通知到你。推到手机或聊天软件的渠道在 设置 → 通知 里配置。",
        "Send a test": "发一条测试", "Keep the notch lit after a restart.": "重启电脑后刘海照样亮着。",
        "Turn on": "开启", "You can open this guide again from Settings → General.": "以后可以在 设置 → 通用 里重新打开这个向导。", "Done": "完成",
        "Connected · %@ used %d%%": "已连接 · %@已用 %d%%", "Sign in with `%@` in a terminal, then retry.": "在终端里运行 `%@` 登录，然后点重试。",
        "macOS will ask once whether Aureole may read the Claude Code Keychain item: choose Always Allow.": "macOS 会问一次能否读取 Claude Code 的钥匙串项目，请选「始终允许」。",
        "Open the welcome guide…": "打开欢迎向导…",
        "Codex hooks": "Codex hooks", "Track Codex sessions": "跟踪 Codex 会话",
        "Adds the same helper to ~/.codex/hooks.json. Codex asks you to trust it once: the desktop app prompts at startup; in the CLI, run /hooks.": "在 ~/.codex/hooks.json 里登记同一个小程序。Codex 会要你信任一次：桌面版启动时会弹提示，命令行里运行 /hooks。",
        "Approve requests from the panel": "在面板里批准请求", "wait up to %d s": "最多等 %d 秒",
        "Hover a waiting session to see the full request and choose Allow once or Deny, or pick an answer when Claude asks a question. When Claude Code itself offers a standing rule, \"Always allow\" adds exactly that rule, named on the button. Nothing is ever allowed without a click. While Aureole waits, the terminal prompt is held back; if you do not answer in time, it appears as usual.": "鼠标移到等你的会话上，详情卡会显示完整请求，可选「允许这一次」或「拒绝」；Claude 提问时也能直接点选答案。如果 Claude Code 自己给出了一条长期规则，「以后都允许」只会加这一条，规则就写在按钮上。没有你的点击绝不会放行。Aureole 等待期间终端里的确认框会暂缓出现；你没及时回应，它就照常弹出。",
        "Other hooks on the same events: %@. If one of them also answers permission prompts or announces finished turns, you may get every alert twice; turn one of them off.": "同样的事件上还挂着别的回调：%@。如果其中有工具也在处理批准请求或播报「做完了」，提醒可能会来两遍，关掉其中一个即可。",
        "Lanes for your own scripts": "给自己的脚本加横道",
        "Any script can put a lane on the time axis: a nightly job, a long build, a batch of renders. It leaves when the script exits.": "任何脚本都能在时间轴上放一条横道，比如夜间任务、长时间编译、一批生图。脚本退出后横道自动消失。",
        "States: working, waiting (needs you), done, idle, end. Optional: --detail, --progress 0.4 or 40%, --open a path or URL.": "状态：working 在干活、waiting 等你、done 完成、idle 空闲、end 移除。可选：--detail 说明、--progress 0.4 或 40%、--open 点击时打开的路径或网址。",
        "Copy": "复制", "Hide or show the notch (%@)": "隐藏或显示刘海面板（%@）", "Hide or show Aureole": "隐藏或显示 Aureole",
        "Allow once": "允许这一次", "Always allow": "以后都允许",
        "Allows this now and adds the rule %@ to Claude Code's permissions, as its own prompt would.": "这次放行，并把规则 %@ 加进 Claude Code 的权限设置，和它自己弹窗里的「以后都允许」一样。",
        "Allowed, and from now on without asking. %@ carries on.": "已允许，以后不再问。%@ 继续干活。",
        "folder %@": "可访问 %@ 文件夹", "accept edits": "自动接受编辑", "%@ (this session)": "%@（仅本会话）", "%d%% of quota": "占额度 %d%%", "%@ tokens": "%@ tokens", "cache %d%%": "缓存命中 %d%%",
        "Tokens": "用量", "Open": "打开", "running": "运行中", "Used by": "谁用的", "other": "其他",
        "≈%@ at API prices": "按 API 价 ≈%@",
        "At public API prices. With a subscription this is what the work would have cost, not what you paid.": "按厂商公开的 API 价格折算。订阅用户实际并没有付这笔钱，这是这些活按 API 计费会花多少。",
        "Each rise of the curve is split among the sessions that spent tokens at that moment, by what those tokens cost at API prices. An estimate: vendors do not say which session used what. Rises with no tokens behind them (another Mac, the web app) count as other.": "曲线每上升一段，就按那段时间里各会话花掉的 token（按 API 价折算）分摊给它们。这是估算：厂商不会告诉你哪个会话用了多少。找不到对应 token 的上升（另一台 Mac、网页版）记为「其他」。", "mode %@": "模式 %@", "Task": "任务", "Deny": "拒绝", "Terminal asks in %d s": "%d 秒后交回终端确认",
        "Approve here": "可在此批准",
        "Detected on this Mac": "在这台 Mac 上检测到", "Scan again": "重新扫描", "not found": "未检测到",
        "running in %@": "正在运行于 %@", "command line": "命令行", "%@ desktop app": "%@ 桌面版",
        "In a terminal: a click jumps to the session's tab.": "在终端里运行：点会话会跳到它所在的标签页。",
        "In a desktop app: a click brings the app forward (it cannot open a specific conversation).": "在桌面 app 里运行：点会话会把该 app 调到前面（无法直接定位到具体对话）。",
        "No Claude Code or Codex found. Install one, then scan again.": "没有检测到 Claude Code 或 Codex。安装后点「重新扫描」。",
        "kitty: to jump to a window, set allow_remote_control and listen_on in kitty.conf.": "kitty：要跳到具体窗口，需在 kitty.conf 里设置 allow_remote_control 和 listen_on。",
        "Ghostty: tab jumps need Ghostty 1.3 or later; macOS asks once to let Aureole control it.": "Ghostty：跳到标签页需要 1.3 或更新版本；macOS 会问一次是否允许 Aureole 控制它。",
        "Switch to %@": "切换到 %@",
        "Too late: the terminal is already asking. Answer it there.": "晚了一步：终端里已经在问了，请到终端处理。",
        "Allowed. %@ carries on.": "已允许，%@ 继续执行。", "Denied. %@ was told no.": "已拒绝，已告知 %@。",
        "Esc closes the panel": "按 Esc 收起面板", "Needs Accessibility": "需要辅助功能权限", "Allow…": "授权…",
        "Ambient motion (breathing glow, flowing forecast)": "环境动效（光带呼吸、预测线流动）",
        "Off automatically when macOS is set to reduce motion.": "macOS 开启「减少动态效果」时自动关闭。",
        "working": "干活中", "Last: %@": "上次：%@", "Panel layout": "面板样式", "Horizon": "晨昏线", "List": "列表", "Session tracking is off.": "会话跟踪已关闭。",
        "Context %% is an estimate (200k or 1M window).": "上下文百分比是估算（按 20 万或 100 万窗口）。",
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
        "WeChat": "微信", "Custom webhook": "自定义 Webhook", "Shell script": "Shell 脚本",
        "Uses Notification Center. Allow notifications when macOS asks.": "使用通知中心，macOS 询问时请允许。",
        "Channel settings → Integrations → Webhooks → copy URL.": "频道设置 → 整合 → Webhook → 复制地址。",
        "Incoming Webhook URL from api.slack.com/apps.": "在 api.slack.com/apps 创建 Incoming Webhook 并复制地址。",
        "Bot token from @BotFather and your chat id (message @userinfobot).": "向 @BotFather 申请机器人 Token，向 @userinfobot 获取你的会话 ID。",
        "Group → Settings → Bots → Custom bot → webhook URL.": "群设置 → 群机器人 → 添加自定义机器人 → 复制 Webhook 地址。",
        "Group robot webhook URL (security setting: custom keyword ‘Aureole’).": "群机器人 Webhook 地址（安全设置选「自定义关键词」填 Aureole）。",
        "Group robot webhook URL.": "群机器人 Webhook 地址。",
        "Topic URL, e.g. https://ntfy.sh/my-aureole.": "主题地址，例如 https://ntfy.sh/my-aureole。",
        "Server URL (default https://api.day.app) and your device key.": "服务器地址（默认 https://api.day.app）和你的设备密钥。",
        "Personal WeChat has no push API for apps, so messages go through ServerChan, a third-party relay: follow its official account at sct.ftqq.com and paste the SendKey it gives you. Its free plan limits messages per day.": "个人微信没有给软件用的推送接口，消息要经第三方中转服务 Server酱：在 sct.ftqq.com 扫码关注它的公众号，把拿到的 SendKey 填在这里。免费版每天的条数有上限。",
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
        "Background": "后台",
        "Started without a terminal or with -p / exec. Shown here, never notified.": "没有终端、或以 -p / exec 启动的无人值守任务。只在这里显示，不推送通知。",
        "Background %d": "后台 %d",
        "Muted": "已静音",
        "Mute": "静音",
        "Notifications for this session are off. Click to turn them back on.": "这个会话的通知已关闭，点一下重新打开。",
        "No more notifications for this session. It stays on the panel.": "不再推送这个会话的通知，面板里照常显示。",
        "Send answer": "发送回答",
        "Answered. %@ carries on.": "已回答，%@ 继续干活。",
        "Paid usage beyond your plan, as Claude reports it.": "超出套餐的付费用量，数字来自 Claude。",
        "These numbers are old: the last refresh failed or was rate limited. They update by themselves once the connection is back.": "这些数字已经过时：上次刷新失败或被限流。网络恢复后会自动更新。",
        "Notch screen": "刘海所在屏幕",
        "Main display": "主显示器",
        "Screen with the pointer": "鼠标所在的屏幕",
        "Show the panel on": "面板显示在",
        "The panel moves to the screen you point at. Without a notch it hangs from the top centre.": "鼠标移到哪块屏幕，面板就跟到哪块；没有刘海的屏幕会挂在顶部正中。",
        "Quiet hours": "免打扰时段",
        "From": "从",
        "To": "到",
        "Nothing is pushed in these hours, to macOS or to any channel. The panel still shows everything.": "这段时间里不推送任何通知（系统通知和所有渠道都不发），面板照常显示。",
        "Copied": "已复制",
        "Copy diagnostics": "复制诊断信息",
        "Version, macOS, what is installed and recent errors, for a bug report. No tokens, prompts or session names.": "版本、系统、安装状态和最近的错误，方便报 bug。不含 token、提示词和会话名。",
        "Uninstall Aureole…": "卸载 Aureole…",
        "Install and relaunch": "安装并重启",
        "Release notes": "更新说明",
        "Downloading…": "正在下载…",
        "Could not install the update": "更新没能安装",
        "The release page opens so you can install it by hand.": "将打开发布页，你可以手动安装。",
        "Aureole is running from a location it cannot update. Move it to Applications first.": "Aureole 当前所在的位置无法更新，请先把它移到「应用程序」。",
        "This copy is not signed with a Developer ID (a local build), so it cannot check an update.": "这份是本地编译、没有 Developer ID 签名，无法校验更新包。",
        "The download failed.": "下载失败。",
        "The disk image has no app in it.": "磁盘映像里没有找到 app。",
        "The update is not signed by the same developer. Not installed.": "更新包的签名开发者不一致，已拒绝安装。",
        "Expected version %@, found %@.": "应为 %@ 版，实际是 %@ 版。",
        "Update to %@ ›": "更新到 %@ ›",
        "Downloads, checks and installs the new version, then reopens Aureole.": "下载、校验并安装新版本，然后重新打开 Aureole。",
        "Uninstall Aureole?": "要卸载 Aureole 吗？",
        "This removes Aureole's hooks from ~/.claude/settings.json, ~/.codex/hooks.json and ~/.gemini/settings.json, removes its opencode plugin, puts back the status line you had before, turns off launch at login, moves Aureole's data, logs and the app to the Trash, and quits. Your other hooks and settings are kept.": "将从 ~/.claude/settings.json、~/.codex/hooks.json、~/.gemini/settings.json 里移除 Aureole 的 hooks，删掉它的 opencode 插件，恢复你原来的状态栏，关闭登录时启动，把 Aureole 的数据、日志和 app 本身移到废纸篓，然后退出。你自己的其他 hooks 和设置原样保留。",
        // spend history
        "Spend": "花费", "Show": "范围", "30 days": "30 天", "90 days": "90 天", "1 year": "1 年",
        "Reading the transcripts…": "正在读取会话记录…",
        "No token use found in Claude Code or Codex transcripts yet.": "还没在 Claude Code 或 Codex 的会话记录里找到 token 用量。",
        "%@ at API prices over these days, about %@ a day on days with use.": "这段时间按 API 价合计 %@，有用量的日子平均每天约 %@。",
        "Values at public API prices, read from the transcripts on this Mac. A subscription costs what it costs; this shows how much work it covered. Kept for 400 days, or as far back as the transcripts go (sessions Codex has compressed into .zst archives are not read).":
            "按官方 API 公开价折算，数据来自本机的会话记录。订阅费是固定的，这里看的是它替你干了多少活。最多保留 400 天，或会话记录能追溯到的最早一天（Codex 压缩成 .zst 的旧会话读不了）。",
        "Gemini CLI hooks": "Gemini CLI hooks", "opencode plugin": "opencode 插件",
        "Gemini CLI: the helper goes into ~/.gemini/settings.json and runs only in folders you trust in Gemini CLI. opencode: a small plugin file in ~/.config/opencode/plugins; restart opencode after adding it. Both show sessions and token use; approving from the panel works with Claude Code and Codex only.":
            "Gemini CLI：辅助程序写进 ~/.gemini/settings.json，只在你于 Gemini CLI 里信任过的文件夹中运行。opencode：在 ~/.config/opencode/plugins 放一个小插件文件，装好后重启 opencode。两者都会显示会话和 token 用量；在面板里批准只支持 Claude Code 和 Codex。",
        "Uninstall": "卸载",
        "Cancel": "取消",
    ]
}
