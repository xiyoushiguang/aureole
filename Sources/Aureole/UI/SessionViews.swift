import SwiftUI
import AureoleCore

/// Every agent session in one list: the ones waiting on you first, then the busy ones, then idle.
/// One click jumps to the session's terminal.
struct TaskList: View {
    @ObservedObject var sessions: SessionStore
    let maxHeight: CGFloat
    weak var actions: AppActions?
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let b = sessions.board
        if b.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("No agent sessions right now.")).font(.system(size: 11)).foregroundStyle(Theme.dim)
                if sessions.hookStatus == .notInstalled {
                    Text(L10n.t("Install the Claude Code hooks in Settings → Sessions to see them here."))
                        .font(.system(size: 10.5)).foregroundStyle(Theme.amber)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView(.vertical, showsIndicators: contentHeight > maxHeight) {
                VStack(alignment: .leading, spacing: 3) {
                    group(L10n.f("Needs you %d", b.waiting.count), b.waiting, color: Theme.amber)
                    group(L10n.f("Done %d", b.done.count), b.done, color: Theme.done, done: true)
                    group(L10n.f("Working %d", b.working.count), b.working, color: Color.white.opacity(0.62))
                    group(L10n.f("Idle %d", b.idle.count), b.idle, color: Theme.dim)
                }
                .background(GeometryReader { g in Color.clear.preference(key: TaskListHeightKey.self, value: g.size.height) })
            }
            .frame(height: min(max(contentHeight, 1), maxHeight))
            .onPreferenceChange(TaskListHeightKey.self) { contentHeight = $0 }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ list: [AgentSession], color: Color, done: Bool = false) -> some View {
        if !list.isEmpty {
            Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color)
                .padding(.top, 4).padding(.leading, 2)
            ForEach(list) { TaskRow(session: $0, sessions: sessions, actions: actions, done: done) }
        }
    }
}

private struct TaskListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Two lines per session: name and state, then what it is doing and for how long.
struct TaskRow: View {
    let session: AgentSession
    @ObservedObject var sessions: SessionStore
    weak var actions: AppActions?
    var done = false
    @State private var hovered = false

    var body: some View {
        let s = session
        let waiting = s.state.needsYou
        Button { actions?.jump(to: s) } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(SessionText.dot(s)).frame(width: 8, height: 8)
                    .shadow(color: waiting ? Theme.amber.opacity(0.9) : .clear, radius: 4)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(sessions.name(of: s))
                            .font(.system(size: 13, weight: waiting ? .semibold : .medium))
                            .foregroundStyle(Color.white.opacity(s.state == .idle ? 0.6 : 0.95))
                        Spacer(minLength: 8)
                        SessionBadge(session: s, done: done)
                    }
                    HStack(spacing: 8) {
                        Text(doing(s))
                            .font(waiting ? .system(size: 11, design: .monospaced) : .system(size: 11))
                            .foregroundStyle(waiting ? Theme.amber.opacity(0.9) : Theme.dim)
                        Spacer(minLength: 8)
                        SessionMeta(session: s, context: sessions.contextFraction(s.id))
                    }
                }
                .lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(
                waiting ? Theme.amber.opacity(hovered ? 0.16 : 0.10) : Color.white.opacity(hovered ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help([s.cwd, s.promptPreview].compactMap { $0 }.joined(separator: "\n"))
    }

    /// What it is doing (or asking) right now, in one line.
    private func doing(_ s: AgentSession) -> String {
        switch s.state {
        case .waitingPermission, .waitingInput:
            return s.waitingMessage ?? s.lastDetail ?? L10n.t("Waiting on you")
        case .working:
            if let t = s.lastTool { return [t, s.lastDetail].compactMap { $0 }.joined(separator: " · ") }
            return L10n.t("thinking")
        case .idle, .ended:
            return s.promptPreview.map { L10n.f("Last: %@", $0) } ?? (s.cwd as NSString).abbreviatingWithTildeInPath
        }
    }

}

/// "Codex · 38m · context 41%", with a long quiet spell or a nearly full context called out in amber.
struct SessionMeta: View {
    let session: AgentSession
    /// Context used, 0...1.
    let context: Double?

    var body: some View {
        let s = session
        let now = Date()
        let quiet = SessionHealth.silence(s, now: now)
        let full = (context ?? 0) >= SessionHealth.contextNearlyFull
        let base = (s.provider == .codex ? ["Codex"] : []) + [Formatting.countdown(now.timeIntervalSince(s.startedAt))]
        HStack(spacing: 0) {
            Text(base.joined(separator: " · ")).foregroundStyle(Theme.dim)
            if let c = context {
                let pct = Int((c * 100).rounded())
                Text(" · " + (full ? L10n.f("context %d%% · nearly full", pct) : L10n.f("context %d%%", pct)))
                    .foregroundStyle(full ? Theme.amber : Theme.dim)
            }
            if let q = quiet {
                Text(" · " + L10n.f("quiet %@", Formatting.countdown(q))).foregroundStyle(Theme.amber)
            }
        }
        .font(.system(size: 10.5).monospacedDigit())
        .lineLimit(1)
        .fixedSize()
        .help([quiet != nil ? L10n.t("No events for a while. A long build or test is normal; otherwise take a look.") : nil,
               full ? L10n.t("Claude Code will compact the conversation soon.") : nil].compactMap { $0 }.joined(separator: "\n"))
    }
}

/// The state pill at the end of a session's first line.
struct SessionBadge: View {
    let session: AgentSession
    /// Finished a task you have not looked at yet (a board placement, not a hook state).
    var done = false

    var body: some View {
        let s = session
        if done {
            pill(L10n.t("done · unseen") + " · " + SessionText.ago(s.stateSince), fill: Theme.done)
        } else {
            switch s.state {
            case .waitingPermission, .waitingInput:
                pill(SessionText.waitStatus(s), fill: Theme.amber)
            case .working:
                Text(L10n.t("working")).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.accent(s.provider))
            case .idle, .ended:
                Text(L10n.t("idle") + " " + Formatting.countdown(Date().timeIntervalSince(s.stateSince)))
                    .font(.system(size: 10.5)).foregroundStyle(Theme.dim)
            }
        }
    }

    private func pill(_ text: String, fill: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color(red: 0.10, green: 0.07, blue: 0.02))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(fill))
            .fixedSize()
    }
}

enum SessionText {
    static func dot(_ s: AgentSession) -> Color {
        switch s.state {
        case .waitingPermission, .waitingInput: return Theme.amber
        case .working: return Theme.accent(s.provider)
        case .idle, .ended: return Theme.faint
        }
    }

    /// "approval · waited 4m"
    static func waitStatus(_ s: AgentSession, now: Date = Date()) -> String {
        let kind = s.state == .waitingInput ? L10n.t("question") : L10n.t("approval")
        return kind + " · " + L10n.f("waited %@", Formatting.countdown(now.timeIntervalSince(s.stateSince)))
    }

    static func status(_ s: AgentSession, now: Date = Date()) -> String {
        switch s.state {
        case .waitingPermission, .waitingInput: return waitStatus(s, now: now)
        case .working:
            if let t = s.lastTool { return [t, s.lastDetail].compactMap { $0 }.joined(separator: " · ") }
            return L10n.t("thinking")
        case .idle: return L10n.t("idle") + " · " + Formatting.countdown(now.timeIntervalSince(s.stateSince))
        case .ended: return ""
        }
    }


    /// "4m ago"
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        return s < 60 ? L10n.t("just now") : L10n.f("%@ ago", Formatting.countdown(s))
    }

    /// Titles and folder names can be long; keep chips compact.
    static func short(_ n: String) -> String {
        n.count > 16 ? String(n.prefix(15)) + "…" : n
    }
}
