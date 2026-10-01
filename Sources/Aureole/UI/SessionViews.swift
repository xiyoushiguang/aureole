import SwiftUI
import AureoleCore

/// First layer: one line that only appears while a session is waiting on the user. Each pill jumps to its terminal.
struct WaitingRow: View {
    let waiting: [AgentSession]
    let name: (AgentSession) -> String
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
                            Text(SessionText.short(name(s))).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white)
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

/// First layer: who is working right now, in one line. Click a chip to jump; the full board is one click away.
struct SessionsRow: View {
    let board: SessionBoard
    let name: (AgentSession) -> String
    weak var actions: AppActions?

    var body: some View {
        let active = board.working.count + board.idle.count
        HStack(alignment: .center, spacing: 14) {
            HStack(spacing: 6) {
                Circle().fill(board.working.isEmpty ? Theme.faint : Color.white.opacity(0.7)).frame(width: 7, height: 7)
                Text(L10n.f("Sessions %d", active))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
            }
            .frame(width: 84, alignment: .leading)
            HStack(spacing: 8) {
                ForEach(board.working.prefix(2)) { s in
                    Button { actions?.jump(to: s) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(Theme.accent(s.provider)).frame(width: 6, height: 6)
                            Text(SessionText.short(name(s))).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color.white.opacity(0.92))
                            Text(s.lastTool ?? L10n.t("thinking")).font(.system(size: 10.5)).foregroundStyle(Theme.dim)
                        }
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help([s.cwd, s.lastDetail].compactMap { $0 }.joined(separator: "\n"))
                }
                if board.working.count > 2 {
                    Text("+\(board.working.count - 2)").font(.system(size: 10.5)).foregroundStyle(Theme.dim)
                }
                if !board.idle.isEmpty {
                    Text(L10n.f("Idle %d", board.idle.count)).font(.system(size: 10.5)).foregroundStyle(Theme.dim)
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
        .onAppear {
            if selected == nil { selected = (b.waiting.first ?? b.working.first)?.id }
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
                    Text(sessions.name(of: s)).font(.system(size: 13, weight: s.state.needsYou ? .semibold : .regular))
                        .foregroundStyle(Color.white.opacity(0.92)).lineLimit(1)
                    Text(SessionText.status(s)).font(.system(size: 10.5))
                        .foregroundStyle(s.state.needsYou ? Theme.amber : Theme.dim).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(SessionText.meta(s, context: sessions.context[s.id])).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.dim).lineLimit(1)
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
                    }
                    if let p = s.promptPreview, !p.isEmpty { detail(L10n.t("Prompt"), p, mono: false) }
                    if let recent = s.recent, !recent.isEmpty {
                        ForEach(Array(recent.enumerated()), id: \.offset) { _, a in
                            detail(SessionText.ago(a.at), a.text, mono: false)
                        }
                    } else if let t = s.lastTool {
                        detail(L10n.t("Last"), [t, s.lastDetail].compactMap { $0 }.joined(separator: " · "), mono: false)
                    }
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

    /// "Claude Code · 38m · context 489k"
    static func meta(_ s: AgentSession, context: Int? = nil, now: Date = Date()) -> String {
        let agent = s.provider == .claude ? "Claude Code" : "Codex"
        var parts = [agent, Formatting.countdown(now.timeIntervalSince(s.startedAt))]
        if let context { parts.append(L10n.f("context %@", TranscriptReader.short(context))) }
        return parts.joined(separator: " · ")
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
