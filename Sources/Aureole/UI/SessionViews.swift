import SwiftUI
import AureoleCore

/// First layer: one line that only appears while a session is waiting on the user. Each pill jumps to its terminal.
struct WaitingRow: View {
    let waiting: [AgentSession]
    weak var actions: AppActions?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(spacing: 6) {
                Circle().fill(Theme.amber).frame(width: 7, height: 7).shadow(color: Theme.amber.opacity(0.9), radius: 3)
                Text(L10n.f("Waiting for you %d", waiting.count))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.amber)
            }
            .frame(width: 84, alignment: .leading)
            HStack(spacing: 8) {
                ForEach(waiting.prefix(3)) { s in
                    Button { actions?.jump(to: s) } label: {
                        HStack(spacing: 8) {
                            Text(s.projectName).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white)
                            Text(SessionText.waitStatus(s)).font(.system(size: 10.5)).foregroundStyle(Color.white.opacity(0.72))
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(Theme.amber.opacity(0.16)))
                    }
                    .buttonStyle(.plain)
                    .help(s.waitingMessage ?? s.cwd)
                }
                if waiting.count > 3 {
                    Text("+\(waiting.count - 3)").font(.system(size: 10.5)).foregroundStyle(Theme.dim)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// Second layer: the session board, grown below the usage rows.
struct WorkbenchSection: View {
    @ObservedObject var sessions: SessionStore
    let hooksInstalled: Bool
    weak var actions: AppActions?
    @State private var selected: String?
    @State private var showIdle = false

    var body: some View {
        let b = sessions.board
        VStack(alignment: .leading, spacing: 6) {
            if b.isEmpty {
                Text(L10n.t("No agent sessions right now.")).font(.system(size: 11)).foregroundStyle(Theme.dim)
                if !hooksInstalled {
                    Text(L10n.t("Install the Claude Code hooks in Settings → Sessions to see them here."))
                        .font(.system(size: 10.5)).foregroundStyle(Theme.amber)
                }
            }
            if !b.waiting.isEmpty {
                label(L10n.f("Needs you %d", b.waiting.count), color: Theme.amber)
                ForEach(b.waiting) { row($0) }
            }
            if !b.working.isEmpty {
                label(L10n.f("Working %d", b.working.count), color: Theme.dim)
                ForEach(b.working) { row($0) }
            }
            if !b.idle.isEmpty {
                Button { showIdle.toggle() } label: {
                    HStack {
                        Text(L10n.f("Idle %d", b.idle.count)).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.dim)
                        Spacer()
                        Text(showIdle ? "⌄" : "›").font(.system(size: 10.5)).foregroundStyle(Theme.dim)
                    }
                    .frame(height: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showIdle { ForEach(b.idle) { row($0) } }
            }
        }
    }

    private func label(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color).padding(.top, 2)
    }

    @ViewBuilder
    private func row(_ s: AgentSession) -> some View {
        let open = selected == s.id
        VStack(alignment: .leading, spacing: 8) {
            Button {
                selected = open ? nil : s.id
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(SessionText.dot(s)).frame(width: 7, height: 7)
                    Text(s.projectName).font(.system(size: 13, weight: s.state.needsYou ? .semibold : .regular))
                        .foregroundStyle(Color.white.opacity(0.92)).lineLimit(1)
                    Text(SessionText.status(s)).font(.system(size: 10.5))
                        .foregroundStyle(s.state.needsYou ? Theme.amber : Theme.dim).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(SessionText.meta(s)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.dim).lineLimit(1)
                    Text(open ? "⌄" : "›").font(.system(size: 10.5)).foregroundStyle(Theme.dim)
                }
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    if let m = s.waitingMessage {
                        detail(L10n.t("Requesting"), m, mono: true)
                    } else if let t = s.lastTool {
                        detail(L10n.t("Last"), [t, s.lastDetail].compactMap { $0 }.joined(separator: " · "), mono: false)
                    }
                    if let p = s.promptPreview, !p.isEmpty { detail(L10n.t("Prompt"), p, mono: false) }
                    detail(L10n.t("Folder"), s.cwd, mono: false)
                    Button { actions?.jump(to: s) } label: {
                        Text(L10n.t("Jump to terminal"))
                            .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.black)
                            .padding(.horizontal, 14).frame(height: 26)
                            .background(Capsule().fill(Color.white))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 15)
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, open ? 4 : 0)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(open ? 0.08 : 0)))
    }

    private func detail(_ key: String, _ value: String, mono: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(key).font(.system(size: 10.5)).foregroundStyle(Color.white.opacity(0.62)).frame(width: 52, alignment: .leading)
            Text(value).font(mono ? .system(size: 10.5, design: .monospaced) : .system(size: 10.5))
                .foregroundStyle(Color.white.opacity(0.86)).lineLimit(2)
        }
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

    /// "Claude Code · 38m"
    static func meta(_ s: AgentSession, now: Date = Date()) -> String {
        let agent = s.provider == .claude ? "Claude Code" : "Codex"
        return agent + " · " + Formatting.countdown(now.timeIntervalSince(s.startedAt))
    }
}
