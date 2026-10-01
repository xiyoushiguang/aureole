import SwiftUI
import AureoleCore

/// Inputs both horizon layers share: which window rides the horizon and what sits in the corner.
struct HorizonInputs {
    let main: ProviderID
    let window: UsageWindow?
    let prediction: Prediction?
    let samples: [Sample]
    /// The other provider, shown as a number in the top-right corner.
    let side: ProviderID?

    @MainActor
    init(store: UsageStore, settings: SettingsStore) {
        let enabled = ProviderID.allCases.filter { settings.isEnabled($0) }
        // Claude rides the horizon unless it is off or has nothing to show while Codex does.
        let main = enabled.first { store.snapshots[$0]?.primary != nil } ?? enabled.first ?? .claude
        self.main = main
        window = store.snapshots[main]?.primary
        prediction = store.predictions[main]
        samples = window.map { store.history.samples(provider: main, key: $0.key) } ?? []
        side = enabled.first { $0 != main }
    }

    func scene(_ layout: HorizonLayout, now: Date, board: SessionBoard) -> HorizonScene {
        HorizonScene(layout: layout, now: now, window: window, samples: samples, prediction: prediction, sessions: board)
    }
}

// MARK: - Drawing

/// Paints a scene: planet, lit horizon, usage, forecast, and session orbits. Labels that need hover live in overlays.
struct HorizonCanvas: View {
    let scene: HorizonScene
    var sky = true
    var showPace = true

    var body: some View {
        Canvas { ctx, size in
            let L = scene.layout
            let s = size.width / L.width
            ctx.scaleBy(x: s, y: s)
            draw(&ctx, L)
        }
    }

    private func line(_ pts: [CGPoint]) -> Path {
        var p = Path()
        p.addLines(pts)
        return p
    }

    private func label(_ ctx: inout GraphicsContext, _ text: String, at p: CGPoint, anchor: UnitPoint = .center,
                       size: CGFloat = 10, weight: Font.Weight = .regular, color: Color = HorizonColor.label) {
        ctx.draw(Text(text).font(.system(size: size, weight: weight).monospacedDigit()).foregroundColor(color), at: p, anchor: anchor)
    }

    private func draw(_ ctx: inout GraphicsContext, _ L: HorizonLayout) {
        let H = L.horizon
        let now = scene.nowAngle
        let full = L.maxOrbits > 3

        if sky {
            ctx.fill(Path(CGRect(x: 0, y: 0, width: L.width, height: L.height)),
                     with: .linearGradient(Gradient(colors: [Color(hex: 0x05060C), Color(hex: 0x0B1428)]),
                                           startPoint: .zero, endPoint: CGPoint(x: 0, y: L.height)))
        }

        // Orbit guides.
        for r in scene.guideRadii {
            ctx.stroke(line(L.arc(from: L.minAngle - 4, to: L.maxAngle + 4, r: r)),
                       with: .color(.white.opacity(r == L.idleOrbit ? 0.07 : 0.09)),
                       style: StrokeStyle(lineWidth: 1, dash: [2, 7]))
        }

        // No-quota stretch and the 100% line.
        let top = scene.hundredRadius
        if let a = scene.dryFrom, let b = scene.dryTo, b > a {
            var sector = line(L.arc(from: a, to: b, r: top))
            sector.addLines(L.arc(from: b, to: a, r: H))
            sector.closeSubpath()
            ctx.fill(sector, with: .color(Theme.amber.opacity(0.14)))
        }
        if scene.window != nil {
            let end = scene.dryFrom ?? L.maxAngle
            ctx.stroke(line(L.arc(from: scene.litFrom, to: end, r: top)), with: .color(.white.opacity(0.12)), lineWidth: 1)
            if let a = scene.dryFrom, let b = scene.dryTo, b > a {
                ctx.stroke(line(L.arc(from: a, to: b, r: top)), with: .color(Theme.amber),
                           style: StrokeStyle(lineWidth: 2, dash: [5, 5]))
            }
            if full {
                label(&ctx, "100%", at: L.point(scene.litFrom, top + 6), anchor: .bottomLeading)
            }
        }

        // Glow of the lit stretch and the sun, behind the planet.
        let lit = L.arc(from: scene.litFrom, to: now, r: H)
        let sunrise = L.point(scene.litFrom, H), sun = scene.sun
        let litShading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [Theme.claude, Theme.amber]), startPoint: sunrise, endPoint: sun)
        ctx.drawLayer { g in
            g.addFilter(.blur(radius: full ? 16 : 10))
            g.stroke(line(lit), with: litShading, style: StrokeStyle(lineWidth: full ? 40 : 24, lineCap: .round))
            g.opacity = 0.75
            let r: CGFloat = full ? 26 : 16
            g.fill(Path(ellipseIn: CGRect(x: sun.x - r, y: sun.y - r, width: 2 * r, height: 2 * r)), with: .color(Color(hex: 0xFFE2B0).opacity(0.9)))
        }

        // The planet.
        let c = L.center
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - H, y: c.y - H, width: 2 * H, height: 2 * H)),
                 with: .linearGradient(Gradient(colors: [Color(hex: 0x070A16), Color(hex: 0x020308)]),
                                       startPoint: CGPoint(x: 0, y: L.point(0, H).y), endPoint: CGPoint(x: 0, y: L.height)))

        // Usage so far, filled down to the horizon.
        if scene.curve.count >= 2, let first = scene.curve.first {
            var area = line(scene.curve)
            area.addLines(L.arc(from: now, to: angle(of: first, L), r: H))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(Gradient(colors: [HorizonColor.claudeBright.opacity(0.55), Theme.claude.opacity(0.10)]),
                                                 startPoint: CGPoint(x: 0, y: L.point(now, top).y), endPoint: CGPoint(x: 0, y: sun.y)))
            ctx.stroke(line(scene.curve), with: .color(HorizonColor.claudeBright),
                       style: StrokeStyle(lineWidth: full ? 2.5 : 2, lineCap: .round, lineJoin: .round))
        }

        if showPace, scene.paceLine.count >= 2 {
            ctx.stroke(line(scene.paceLine), with: .color(.white.opacity(0.22)), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            if full {
                let mid = scene.paceLine[scene.paceLine.count / 2 + 1]
                label(&ctx, L10n.t("Steady pace"), at: CGPoint(x: mid.x, y: mid.y + 8), anchor: .top)
            }
        }

        // Forecast.
        if let (from, to) = scene.forecast {
            ctx.stroke(line([from, to]), with: .color(Theme.amber), style: StrokeStyle(lineWidth: 2, dash: [5, 5]))
            if let at = scene.exhaustAt, scene.dryFrom != nil {
                ctx.fill(Path(ellipseIn: CGRect(x: to.x - 5, y: to.y - 5, width: 10, height: 10)), with: .color(Theme.amber))
                label(&ctx, Formatting.clock(at), at: CGPoint(x: to.x, y: to.y - 9), anchor: .bottom,
                      size: full ? 11.5 : 10.5, weight: .bold, color: Theme.amber)
                if full, let a = scene.dryFrom, let b = scene.dryTo, let reset = scene.window?.resetsAt {
                    let mid = L.point((a + b) / 2, (H + top) / 2 + 8)
                    label(&ctx, L10n.f("No quota here, about %@", Formatting.countdown(reset.timeIntervalSince(at))),
                          at: mid, size: 10.5, color: .white.opacity(0.78))
                }
            }
        }

        // Horizon line, brighter where the window has been lit.
        ctx.stroke(line(L.arc(from: L.minAngle - 6, to: scene.litFrom, r: H)), with: .color(.white.opacity(0.18)), lineWidth: 2)
        ctx.stroke(line(L.arc(from: now, to: L.maxAngle + 6, r: H)), with: .color(.white.opacity(0.18)), lineWidth: 2)
        if scene.window != nil {
            ctx.stroke(line(lit), with: litShading, style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }

        // Time ticks.
        for t in scene.ticks {
            ctx.stroke(line([L.point(t.angle, H), L.point(t.angle, H - 8)]), with: .color(.white.opacity(0.4)), lineWidth: 1)
            let text: String
            switch t.kind {
            case .hour: text = Formatting.clock(t.date)
            case .windowStart: text = L10n.f("%@ start", Formatting.clock(t.date))
            case .reset: text = L10n.f("%@ reset", Formatting.clock(t.date))
            }
            label(&ctx, text, at: L.point(t.angle, H - (full ? 20 : 15)), size: full ? 10 : 9.5)
        }

        // Session orbits.
        for o in scene.orbits {
            for a in o.arcs {
                let pts = L.arc(from: a.from, to: a.to, r: o.radius, step: 0.1)
                let width: CGFloat = o.role == .idle ? (full ? 8 : 5) : (full ? 10 : 6)
                let color: Color = o.role == .idle ? .white.opacity(0.22)
                    : a.kind == .waiting ? Theme.amber : Theme.accent(o.session.provider)
                ctx.stroke(line(pts), with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
                if a.kind == .waiting, o.role != .idle {
                    // A white core tells waiting apart from Claude's similar orange.
                    ctx.stroke(line(pts), with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
            }
        }

        // "Now": a radial line up through the orbits, the sun, and the current usage.
        let nowTop = L.point(now, (L.maxOrbits > 3 ? L.idleOrbit : L.orbitOuter) + (full ? 18 : 10))
        ctx.stroke(line([L.point(now, H - (full ? 12 : 6)), nowTop]), with: .color(.white.opacity(0.7)), lineWidth: full ? 1.5 : 1)
        if full {
            let pill = ctx.resolve(Text(L10n.f("Now %@", Formatting.clock(scene.clock.now)))
                .font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundColor(.black))
            let ts = pill.measure(in: CGSize(width: 200, height: 40))
            let box = CGRect(x: nowTop.x - ts.width / 2 - 7, y: nowTop.y - 16, width: ts.width + 14, height: 16)
            ctx.fill(Path(roundedRect: box, cornerRadius: 8), with: .color(.white))
            ctx.draw(pill, at: CGPoint(x: box.midX, y: box.midY))
        }
        ctx.fill(Path(ellipseIn: CGRect(x: sun.x - 7, y: sun.y - 7, width: 14, height: 14)), with: .color(.white))
        if let cur = scene.current, let w = scene.window {
            ctx.fill(Path(ellipseIn: CGRect(x: cur.x - 5, y: cur.y - 5, width: 10, height: 10)), with: .color(HorizonColor.claudeBright))
            ctx.stroke(Path(ellipseIn: CGRect(x: cur.x - 5, y: cur.y - 5, width: 10, height: 10)), with: .color(.white), lineWidth: 1.5)
            label(&ctx, L10n.f("Used %d%%", Int(w.usedPercent.rounded())), at: CGPoint(x: cur.x - 10, y: cur.y - 6),
                  anchor: .bottomTrailing, size: full ? 10.5 : 10, weight: .semibold, color: HorizonColor.claudeBright)
        }
    }

    private func angle(of p: CGPoint, _ L: HorizonLayout) -> Double {
        atan2(p.x - L.center.x, L.center.y - p.y) * 180 / .pi
    }
}

enum HorizonColor {
    static let claudeBright = Color(hex: 0xEE8E6C)
    static let codexBright = Color(hex: 0x7FDCC9)
    static let label = Color.white.opacity(0.62)

    static func dot(_ o: HorizonOrbit) -> Color {
        switch o.role {
        case .waiting: return Theme.amber
        case .working: return o.session.provider == .claude ? claudeBright : codexBright
        case .idle: return .white.opacity(0.45)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Session lights

/// One session's light: a context ring around a coloured core, an amber halo when it needs you.
struct SessionLight: View {
    let orbit: HorizonOrbit
    let context: Double?
    var compact = false
    @State private var pulse = false

    var body: some View {
        let color = HorizonColor.dot(orbit)
        let r: CGFloat = compact ? 7 : 11
        ZStack {
            if orbit.role == .waiting {
                Circle().stroke(Theme.amber.opacity(0.45), lineWidth: 1.5)
                    .frame(width: (compact ? 11 : 18) * 2, height: (compact ? 11 : 18) * 2)
                    .scaleEffect(pulse ? 1.18 : 0.94)
                    .opacity(pulse ? 0.35 : 1)
                Circle().fill(Theme.amber.opacity(0.6)).frame(width: r * 2.4, height: r * 2.4).blur(radius: compact ? 3 : 5)
            }
            if orbit.role == .idle {
                Circle().fill(color).frame(width: 10, height: 10)
            } else if orbit.session.provider == .codex || context == nil {
                Circle().fill(color.opacity(0.6)).frame(width: r * 1.6, height: r * 1.6).blur(radius: 4)
                Circle().fill(color).frame(width: compact ? 8 : 12, height: compact ? 8 : 12)
            } else {
                Circle().fill(Color(hex: 0x05060C)).frame(width: r * 2, height: r * 2)
                Circle().stroke(Color.white.opacity(0.2), lineWidth: compact ? 2 : 3).frame(width: r * 2, height: r * 2)
                Circle().trim(from: 0, to: context ?? 0)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: compact ? 2 : 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: r * 2, height: r * 2)
                Circle().fill(color).frame(width: r, height: r)
            }
        }
        .frame(width: 40, height: 40)
        .contentShape(Circle().inset(by: 6))
        .onAppear {
            guard orbit.role == .waiting else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

// MARK: - Second layer

/// The full horizon: a 1000×600 picture (scaled to fit) with session lights, a summary and a details card.
struct HorizonBoard: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var sessions: SessionStore
    @ObservedObject var settings: SettingsStore
    let width: CGFloat
    weak var actions: AppActions?
    @State private var focus: String?
    @State private var hoveringDot: String?
    @State private var hoveringCard = false

    var height: CGFloat { width * 0.6 }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { ctx in
            content(now: ctx.date)
        }
        .frame(width: width, height: height)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let inputs = HorizonInputs(store: store, settings: settings)
        let board = settings.sessionsEnabled ? sessions.board : SessionBoard()
        let scene = inputs.scene(.full, now: now, board: board)
        let s = width / scene.layout.width
        ZStack(alignment: .topLeading) {
            HorizonCanvas(scene: scene)
            ForEach(scene.orbits) { o in
                light(o, scene: scene, scale: s)
            }
            HorizonHeadlineView(inputs: inputs, store: store, large: true)
                .padding(.leading, 28).padding(.top, 22)
            SideNumber(inputs: inputs, store: store, large: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 28).padding(.top, 26)
            if !board.waiting.isEmpty {
                WaitingCapsule(waiting: board.waiting, name: sessions.name(of:), actions: actions)
                    .frame(maxWidth: .infinity).padding(.top, 19)
            }
            if let id = focus, let o = scene.orbits.first(where: { $0.id == id }) {
                SessionCard(session: o.session, name: sessions.name(of: o.session), context: sessions.context[id], actions: actions)
                    .frame(width: 318)
                    .onHover { hoveringCard = $0; if !$0 { scheduleBlur() } }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 28).padding(.top, 163 * s)
                    .transition(.opacity)
            }
            if settings.sessionsEnabled, board.isEmpty, sessions.hookStatus == .notInstalled {
                Text(L10n.t("Install the Claude Code hooks in Settings → Sessions to see them here."))
                    .font(.system(size: 11)).foregroundStyle(Theme.amber)
                    .position(x: width / 2, y: 260 * s)
            }
            legend.frame(maxHeight: .infinity, alignment: .bottom).padding(.horizontal, 24).padding(.bottom, 14)
        }
        .animation(.easeOut(duration: 0.15), value: focus)
    }

    @ViewBuilder
    private func light(_ o: HorizonOrbit, scene: HorizonScene, scale s: CGFloat) -> some View {
        if let a = o.dotAngle {
            let p = scene.layout.point(a, o.radius)
            let ctx = sessions.context[o.id].map(ContextGauge.fraction(tokens:))
            Button { actions?.jump(to: o.session) } label: { SessionLight(orbit: o, context: ctx) }
                .buttonStyle(.plain)
                .onHover { inside in
                    hoveringDot = inside ? o.id : (hoveringDot == o.id ? nil : hoveringDot)
                    if inside { focus = o.id } else { scheduleBlur() }
                }
                .position(x: p.x * s, y: p.y * s)
            if o.role != .idle {
                SessionLabel(session: o.session, name: sessions.name(of: o.session), context: ctx, role: o.role)
                    .fixedSize()
                    .alignmentGuide(.leading) { _ in 0 }
                    .offset(x: p.x * s + 30, y: p.y * s - 17)
                    .allowsHitTesting(false)
            }
        }
    }

    private func scheduleBlur() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if hoveringDot == nil && !hoveringCard { focus = nil }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            Button(L10n.t("Refresh")) { actions?.refreshNow() }
            Button(L10n.t("Settings…")) { actions?.openSettings() }
            Spacer()
            key(Theme.claude, L10n.t("Claude working"))
            key(Theme.codex, L10n.t("Codex working"))
            key(Theme.amber, L10n.t("Waiting on you"))
            key(.white.opacity(0.3), L10n.t("idle"))
            HStack(spacing: 6) {
                Circle().stroke(Color.white.opacity(0.8), lineWidth: 2).frame(width: 9, height: 9)
                Text(L10n.t("Small ring = context used"))
            }
            .help(L10n.t("Context %% is an estimate (200k or 1M window)."))
            Button(L10n.t("‹ Collapse")) { actions?.toggleWorkbench() }.foregroundStyle(Color.white.opacity(0.78))
        }
        .buttonStyle(.plain)
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(HorizonColor.label)
    }

    private func key(_ c: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(c).frame(width: 14, height: 6)
            Text(text)
        }
    }
}

/// Name and status beside a light, two lines.
struct SessionLabel: View {
    let session: AgentSession
    let name: String
    let context: Double?
    let role: HorizonOrbit.Role
    var compact = false

    var body: some View {
        let waiting = role == .waiting
        if compact {
            HStack(spacing: 6) {
                Text(SessionText.short(name)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
                Text(status).font(.system(size: 10, weight: waiting ? .semibold : .regular))
                    .foregroundStyle(waiting ? Theme.amber : HorizonColor.label)
                    .truncationMode(.tail)
            }
            .lineLimit(1)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: waiting ? 13 : 12, weight: waiting ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(waiting ? 1 : 0.92))
                Text(status).font(.system(size: waiting ? 11 : 10, weight: waiting ? .semibold : .regular))
                    .foregroundStyle(waiting ? Theme.amber : HorizonColor.label)
            }
            .lineLimit(1)
            .frame(maxWidth: 300, alignment: .leading)
        }
    }

    private var status: String {
        var parts: [String] = []
        if session.provider == .codex { parts.append("Codex") }
        if session.state.needsYou {
            parts.append(SessionText.waitStatus(session))
            if !compact, let m = session.waitingMessage { parts.append(m) }
        } else {
            parts.append(SessionText.status(session))
            if !compact, let c = context { parts.append(L10n.f("context %d%%", Int((c * 100).rounded()))) }
        }
        return parts.joined(separator: " · ")
    }
}

/// Details for one session; appears while its light (or the card itself) is hovered.
struct SessionCard: View {
    let session: AgentSession
    let name: String
    let context: Int?
    weak var actions: AppActions?

    var body: some View {
        let s = session
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(SessionText.dot(s)).frame(width: 8, height: 8)
                Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Spacer(minLength: 4)
                if s.state.needsYou {
                    Text(SessionText.waitStatus(s))
                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color(hex: 0x1A1305))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.amber))
                }
            }
            if let m = s.waitingMessage { row(L10n.t("Requesting"), m, mono: true) }
            if let p = s.promptPreview, !p.isEmpty { row(L10n.t("Prompt"), p) }
            if let recent = s.recent, !recent.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(recent.enumerated()), id: \.offset) { _, a in row(SessionText.ago(a.at), a.text) }
                }
            } else if !s.state.needsYou {
                row(L10n.t("Last"), SessionText.status(s))
            }
            if let context {
                let f = ContextGauge.fraction(tokens: context)
                HStack(spacing: 8) {
                    Text(L10n.t("Context")).font(.system(size: 11)).foregroundStyle(HorizonColor.label).frame(width: 52, alignment: .leading)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.12))
                            Capsule().fill(Color.white.opacity(0.75)).frame(width: g.size.width * f)
                        }
                    }
                    .frame(height: 4)
                    Text("\(Int((f * 100).rounded()))% · \(TranscriptReader.short(context))")
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.86))
                }
                .help(L10n.t("Context %% is an estimate (200k or 1M window)."))
            }
            row(L10n.t("Folder"), s.cwd)
            Button { actions?.jump(to: s) } label: {
                Text(L10n.t("Jump to terminal"))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 16).frame(height: 30)
                    .background(Capsule().fill(Color.white))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0x14161D).opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(s.state.needsYou ? Theme.amber.opacity(0.4) : Color.white.opacity(0.12), lineWidth: 1))
    }

    private func row(_ key: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(key).font(.system(size: 11)).foregroundStyle(HorizonColor.label).frame(width: 52, alignment: .leading)
            Text(value).font(mono ? .system(size: 11, design: .monospaced) : .system(size: 11))
                .foregroundStyle(.white.opacity(0.86)).lineLimit(2)
        }
    }
}

/// "Waiting for you 2" with one button per waiting session; a click jumps to its terminal.
struct WaitingCapsule: View {
    let waiting: [AgentSession]
    let name: (AgentSession) -> String
    weak var actions: AppActions?
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            Circle().fill(Theme.amber).frame(width: 8, height: 8).shadow(color: Theme.amber.opacity(0.9), radius: 4)
            Text(L10n.f("Needs you %d", waiting.count))
                .font(.system(size: compact ? 12 : 13, weight: .semibold)).foregroundStyle(Theme.amber)
            ForEach(waiting.prefix(compact ? 2 : 4)) { s in
                Button { actions?.jump(to: s) } label: {
                    Text(SessionText.short(name(s)) + " ›")
                        .font(.system(size: compact ? 11 : 12, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, compact ? 10 : 12).frame(height: compact ? 22 : 28)
                        .background(Capsule().fill(Theme.amber.opacity(0.22)))
                }
                .buttonStyle(.plain)
                .help(s.waitingMessage ?? s.cwd)
            }
            if waiting.count > (compact ? 2 : 4) {
                Text("+\(waiting.count - (compact ? 2 : 4))").font(.system(size: 11)).foregroundStyle(Theme.amber)
            }
        }
        .padding(.leading, 14).padding(.trailing, 8)
        .frame(height: compact ? 30 : 40)
        .background(Capsule().fill(Theme.amber.opacity(0.16)))
    }
}

/// The conclusion first, then the numbers behind it.
struct HorizonHeadlineView: View {
    let inputs: HorizonInputs
    @ObservedObject var store: UsageStore
    var large: Bool

    var body: some View {
        let h = HorizonHeadline(provider: inputs.main, window: inputs.window, prediction: inputs.prediction)
        let status = store.status[inputs.main] ?? .idle
        let color: Color = switch h.tone {
        case .warning: Theme.amber
        case .fine: inputs.main == .claude ? HorizonColor.claudeBright : HorizonColor.codexBright
        case .unknown: .white.opacity(0.9)
        }
        VStack(alignment: .leading, spacing: large ? 4 : 2) {
            Text(h.title)
                .font(.system(size: large ? (h.tone == .fine ? 26 : 38) : (h.tone == .fine ? 17 : 22), weight: .bold).monospacedDigit())
                .foregroundStyle(color)
            if let sub = h.subtitle {
                Text(sub).font(.system(size: large ? 12.5 : 11).monospacedDigit()).foregroundStyle(.white.opacity(0.86))
            }
            if let d = h.detail {
                Text(d).font(.system(size: large ? 11.5 : 10.5).monospacedDigit()).foregroundStyle(HorizonColor.label)
            }
            if inputs.window == nil || status.message != nil {
                Text(placeholder(status)).font(.system(size: 11)).foregroundStyle(status.message == nil ? HorizonColor.label : Theme.amber)
                    .lineLimit(2)
            }
        }
        .lineLimit(1)
    }

    private func placeholder(_ status: ProviderStatus) -> String {
        switch status {
        case .idle, .loading: return L10n.t("Loading…")
        case .ok: return L10n.t("No windows reported")
        case .rateLimited: return L10n.t("Rate limited")
        case .signedOut(let m), .error(let m): return m
        }
    }
}

/// Top right: the other provider as one number, plus the main provider's weekly window.
struct SideNumber: View {
    let inputs: HorizonInputs
    @ObservedObject var store: UsageStore
    var large: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: large ? 3 : 1) {
            if let side = inputs.side, let w = store.snapshots[side]?.primary {
                let h = HorizonHeadline(provider: side, window: w, prediction: store.predictions[side])
                let accent = side == .codex ? HorizonColor.codexBright : HorizonColor.claudeBright
                Text(Formatting.percent(w.usedPercent))
                    .font(.system(size: large ? 30 : 18, weight: .bold).monospacedDigit())
                    .foregroundStyle(h.tone == .warning ? Theme.amber : accent)
                Text(side.displayName + " " + HorizonHeadline.windowName(w) + " · " + h.title)
                    .font(.system(size: large ? 11.5 : 10).monospacedDigit()).foregroundStyle(.white.opacity(0.78))
            } else if let side = inputs.side {
                Text(side.displayName + " —").font(.system(size: large ? 11.5 : 10)).foregroundStyle(HorizonColor.label)
            }
            if let snap = store.snapshots[inputs.main], let weekly = snap.weekly, weekly.key != inputs.window?.key {
                Text(inputs.main.displayName + " " + HorizonHeadline.windowName(weekly) + " " + Formatting.percent(weekly.usedPercent))
                    .font(.system(size: large ? 11.5 : 10).monospacedDigit()).foregroundStyle(HorizonColor.label)
            }
        }
        .lineLimit(1)
    }
}

// MARK: - First layer

/// The first layer in the horizon style: the conclusion, a small horizon, and up to three session lights.
struct HorizonCompact: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var sessions: SessionStore
    @ObservedObject var settings: SettingsStore
    weak var actions: AppActions?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { ctx in
            content(now: ctx.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let inputs = HorizonInputs(store: store, settings: settings)
        let board = settings.sessionsEnabled ? sessions.board : SessionBoard()
        let scene = inputs.scene(.compact, now: now, board: board)
        VStack(spacing: 6) {
            HStack(alignment: .top) {
                HorizonHeadlineView(inputs: inputs, store: store, large: false)
                Spacer(minLength: 12)
                SideNumber(inputs: inputs, store: store, large: false)
            }
            .padding(.horizontal, 22)
            if !board.waiting.isEmpty {
                WaitingCapsule(waiting: board.waiting, name: sessions.name(of:), actions: actions, compact: true)
            }
            ZStack(alignment: .topLeading) {
                HorizonCanvas(scene: scene, sky: false, showPace: true)
                ForEach(scene.orbits) { o in
                    if let a = o.dotAngle {
                        let p = scene.layout.point(a, o.radius)
                        let ctx = sessions.context[o.id].map(ContextGauge.fraction(tokens:))
                        Button { actions?.jump(to: o.session) } label: { SessionLight(orbit: o, context: ctx, compact: true) }
                            .buttonStyle(.plain)
                            .help([sessions.name(of: o.session), SessionText.status(o.session)].joined(separator: "\n"))
                            .position(x: p.x, y: p.y)
                        SessionLabel(session: o.session, name: sessions.name(of: o.session), context: ctx, role: o.role, compact: true)
                            .frame(width: max(60, scene.layout.width - p.x - 38), alignment: .leading)
                            .offset(x: p.x + 16, y: p.y - 7)
                            .allowsHitTesting(false)
                    }
                }
                let hidden = board.waiting.count + board.working.count - scene.orbits.count
                if hidden > 0 || !board.idle.isEmpty {
                    let p = scene.layout.point(scene.nowAngle, scene.layout.orbitOuter + 16)
                    Text([hidden > 0 ? "+\(hidden)" : nil, board.idle.isEmpty ? nil : L10n.f("Idle %d", board.idle.count)]
                            .compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 9.5)).foregroundStyle(HorizonColor.label)
                        .fixedSize()
                        .offset(x: p.x + 16, y: p.y - 6)
                }
            }
            .frame(width: scene.layout.width, height: scene.layout.height)
        }
    }
}
