import SwiftUI
import AureoleCore

struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var store: UsageStore
    @ObservedObject var sessions: SessionStore
    @ObservedObject var settings: SettingsStore
    weak var actions: AppActions?

    var body: some View {
        let size = model.isOpen ? model.openSize : model.closedSize
        ZStack(alignment: .top) {
            backdrop
            if model.isOpen {
                OpenNotchView(model: model, store: store, sessions: sessions, settings: settings, actions: actions)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            } else {
                ClosedNotchView(model: model, store: store)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.36, dampingFraction: 0.84), value: model.isOpen)
        .animation(.easeOut(duration: 0.18), value: model.openContentHeight)
        .id(settings.language)
        .onPreferenceChange(OpenContentHeightKey.self) { h in
            if h > 0 { model.openContentHeight = h }
        }
    }

    /// Solid black, or (when open and enabled) Liquid Glass below a solid band that stays flush with the hardware notch.
    @ViewBuilder
    private var backdrop: some View {
        let shape = NotchShape(bottomRadius: model.isOpen ? 24 : 11, ear: model.ear)
        let edge = shape.stroke(Color.white.opacity(model.isOpen ? 0.10 : 0.0), lineWidth: 0.8).padding(0.4)
        if model.isOpen && settings.panelStyle == .glass {
            ZStack(alignment: .top) {
                glass(in: shape)
                Rectangle()
                    .fill(Color.black)
                    .frame(height: model.geometry.notchRect.height + 1)
                LinearGradient(colors: [Color.black, Color.black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 22)
                    .offset(y: model.geometry.notchRect.height)
            }
            .clipShape(shape)
            .overlay(edge)
        } else {
            shape.fill(Color.black).overlay(edge)
        }
    }

    @ViewBuilder
    private func glass(in shape: NotchShape) -> some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular.tint(Color.black.opacity(0.62)), in: shape)
        } else {
            shape.fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                .overlay(shape.fill(Color.black.opacity(0.45)))
        }
    }
}

/// Closed state: two arcs of light hugging the bottom of the notch, one per provider.
struct ClosedNotchView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var store: UsageStore

    var body: some View {
        let inset: CGFloat = 12
        let gap: CGFloat = 8
        HStack(spacing: gap) {
            halo(.claude, mirrored: true)
            halo(.codex, mirrored: false)
        }
        .padding(.horizontal, inset)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private func halo(_ provider: ProviderID, mirrored: Bool) -> some View {
        let window = store.snapshots[provider]?.primary
        let accent = Theme.accent(provider)
        let remaining = window.map { $0.remainingPercent / 100 } ?? 0
        let color = window.map { Theme.state(for: $0, accent: accent) } ?? Color.white.opacity(0.25)
        let troubled = store.status[provider].map { if case .ok = $0 { return false } else { return true } } ?? false
        return GeometryReader { geo in
            ZStack(alignment: mirrored ? .trailing : .leading) {
                Capsule().fill(Color.white.opacity(0.09))
                if window != nil {
                    Capsule()
                        .fill(LinearGradient(colors: mirrored ? [color, color.opacity(0.35)] : [color.opacity(0.35), color],
                                             startPoint: mirrored ? .trailing : .leading,
                                             endPoint: mirrored ? .leading : .trailing))
                        .frame(width: max(4, geo.size.width * remaining))
                        .shadow(color: color.opacity(0.8), radius: 3)
                } else if troubled {
                    Capsule().fill(Theme.amber.opacity(0.5)).frame(width: 6)
                }
            }
        }
        .frame(height: 2.5)
    }
}

struct OpenNotchView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var store: UsageStore
    @ObservedObject var sessions: SessionStore
    @ObservedObject var settings: SettingsStore
    weak var actions: AppActions?

    var body: some View {
        let notchH = model.geometry.notchRect.height
        VStack(spacing: 0) {
            header.frame(height: notchH)
            VStack(spacing: 10) {
                ForEach(enabledProviders) { provider in
                    ProviderRow(provider: provider, store: store)
                }
                if settings.sessionsEnabled {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                    TaskList(sessions: sessions, maxHeight: taskListMax, actions: actions)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 10)
            .padding(.bottom, settings.showHorizon ? 4 : 10)
            if settings.showHorizon {
                HorizonBoard(store: store, sessions: sessions, settings: settings, width: model.openWidth, actions: actions)
            }
            footer.padding(.horizontal, 22).padding(.top, 4).padding(.bottom, 14)
        }
        .frame(width: model.openWidth, alignment: .top)
        .background(GeometryReader { geo in
            Color.clear.preference(key: OpenContentHeightKey.self, value: geo.size.height)
        })
    }

    /// Whatever height the rows and (optional) horizon leave; past that the task list scrolls.
    private var taskListMax: CGFloat {
        let rows = CGFloat(enabledProviders.count) * 90 + 110
        let horizon = settings.showHorizon ? (600 - HorizonBoard.cropTop) * model.openWidth / 1000 : 0
        return max(160, model.maxOpenHeight - rows - horizon)
    }

    private var enabledProviders: [ProviderID] {
        ProviderID.allCases.filter { settings.isEnabled($0) }
    }

    private var header: some View {
        let notchW = model.geometry.notchRect.width
        return HStack(spacing: 0) {
            Text("AUREOLE")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .tracking(2.4)
                .foregroundStyle(Theme.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer().frame(width: notchW + 8)
            HStack(spacing: 8) {
                if let hint = store.routingHint, settings.routingHints {
                    Text(L10n.f("route new work → %@", hint.suggested.displayName))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.amber)
                }
                Text(updatedText)
                    .font(.system(size: 10, weight: .regular).monospacedDigit())
                    .foregroundStyle(Theme.faint)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 22)
    }

    private var updatedText: String {
        guard let t = store.lastRefresh else { return "…" }
        let s = Int(Date().timeIntervalSince(t))
        return s < 60 ? L10n.t("just now") : L10n.f("%@ ago", Formatting.countdown(TimeInterval(s)))
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button(L10n.t("Refresh")) { actions?.refreshNow() }
            Button(L10n.t("Settings…")) { actions?.openSettings() }
            Spacer()
            Button(L10n.t(model.pinned ? "Unpin" : "Pin")) { actions?.togglePinned() }
        }
        .buttonStyle(.plain)
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(Theme.dim)
        .padding(.top, 2)
    }
}

struct ProviderRow: View {
    let provider: ProviderID
    @ObservedObject var store: UsageStore

    var body: some View {
        let snap = store.snapshots[provider]
        let status = store.status[provider] ?? .idle
        let accent = Theme.accent(provider)
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(accent).frame(width: 7, height: 7).shadow(color: accent.opacity(0.9), radius: 3)
                    Text(provider.displayName).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.white.opacity(0.92))
                }
                Text(snap?.planLabel ?? " ")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim)
            }
            .frame(width: 84, alignment: .leading)

            VStack(alignment: .leading, spacing: 7) {
                if let snap {
                    if let s = snap.session { WindowLine(window: s, accent: accent) }
                    if let w = snap.weekly { WindowLine(window: w, accent: accent) }
                    if let line = detailLine(snap) {
                        Text(line)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(store.predictions[provider]?.exhaustsBeforeReset == true ? Theme.amber : Theme.dim)
                            .lineLimit(1)
                    }
                } else {
                    Text(placeholder(status))
                        .font(.system(size: 11))
                        .foregroundStyle(status.message == nil ? Theme.dim : Theme.amber)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if snap != nil, let msg = status.message {
                    Text(msg).font(.system(size: 10)).foregroundStyle(Theme.amber).lineLimit(1)
                }
                if case .rateLimited(let until) = status {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(L10n.f("Rate limited, retrying in %@", Formatting.countdownSeconds(until.timeIntervalSince(ctx.date))))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(Theme.dim)
                    }
                }
            }
        }
    }

    private func placeholder(_ status: ProviderStatus) -> String {
        switch status {
        case .idle, .loading: return L10n.t("Loading…")
        case .ok: return L10n.t("No windows reported")
        case .rateLimited: return L10n.t("Rate limited")
        case .signedOut(let m), .error(let m): return m
        }
    }

    private func detailLine(_ snap: ProviderSnapshot) -> String? {
        var parts: [String] = []
        if let p = store.predictions[provider] {
            if p.ratePerHour >= 0.5 {
                var s = L10n.f("≈%d%%/h", Int(p.ratePerHour.rounded()))
                if let at = p.exhaustAt {
                    s += L10n.f(p.exhaustsBeforeReset ? " · empty %@, before reset" : " · empty %@", Formatting.clock(at))
                }
                parts.append(s)
            } else if p.basedOnMinutes >= 4 {
                parts.append(L10n.t("idle"))
            }
        }
        let extras = snap.extras.filter { $0.key != "extra_usage" }.map { "\($0.displayLabel) \(Formatting.percent($0.usedPercent))" }
        if !extras.isEmpty { parts.append(extras.joined(separator: " · ")) }
        return parts.isEmpty ? nil : parts.joined(separator: "   ")
    }
}

struct WindowLine: View {
    let window: UsageWindow
    let accent: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(window.displayLabel)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.dim)
                .frame(width: 34, alignment: .leading)
            PaceBar(window: window, accent: accent)
            Text(Formatting.percent(window.usedPercent))
                .font(Theme.mono)
                .foregroundStyle(Theme.state(for: window, accent: accent))
                .frame(width: 40, alignment: .trailing)
            Text(window.resetsAt.map { Formatting.resetText($0) } ?? "—")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(Theme.dim)
                .frame(width: 134, alignment: .leading)
                .lineLimit(1)
        }
    }
}

struct OpenContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
