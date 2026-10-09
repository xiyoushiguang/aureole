import SwiftUI
import AureoleCore

/// Which window rides the horizon, with its history and forecast, and what goes in the top-right corner.
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
}

enum HorizonColor {
    static let claudeBright = Color(hex: 0xEE8E6C)
    static let codexBright = Color(hex: 0x7FDCC9)
    static let label = Color.white.opacity(0.62)
    /// The planet's night side, which the task lanes sit on.
    static let ground = Color(hex: 0x03040A)
    static let nowLine = Color.white.opacity(0.55)

    static func dot(_ lane: HorizonLane) -> Color {
        switch lane.role {
        case .waiting: return Theme.amber
        case .done: return Theme.done
        case .working: return lane.session.provider == .claude ? claudeBright : codexBright
        case .idle: return .white.opacity(0.45)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - The panel

/// One layer: the horizon tells how the quota is going; under it, every session has a lane on the same
/// time axis — its past on the left of "now", its light on the "now" line, and what it is doing on the right.
struct HorizonPanel: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var sessions: SessionStore
    @ObservedObject var settings: SettingsStore
    let width: CGFloat
    /// Room left for the lanes before they scroll.
    let lanesMaxHeight: CGFloat
    let pinned: Bool
    weak var actions: AppActions?
    @State private var lanesHeight: CGFloat = 0
    /// The session whose details card is showing: set by hovering its lane, kept while the card is hovered.
    /// `open Aureole.app --args -debugFocusLane <session id>` starts with one card up, for screenshots.
    @State private var focus: String? = UserDefaults.standard.string(forKey: "debugFocusLane")
    @State private var hoveredLane: String?
    @State private var hoveringCard = false

    static let laneHeight: CGFloat = 52

    var body: some View {
        // Every few seconds, so the time axis creeps along instead of jumping.
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            content(now: ctx.date)
        }
        .frame(width: width)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let inputs = HorizonInputs(store: store, settings: settings)
        let board = settings.sessionsEnabled ? sessions.board : SessionBoard()
        let scene = HorizonScene(layout: .band, now: now, window: inputs.window, samples: inputs.samples,
                                 prediction: inputs.prediction, sessions: board)
        let s = width / scene.layout.width
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                HorizonArc(inputs: inputs, now: now, board: board, used: inputs.window?.usedPercent ?? 0,
                           ambient: settings.ambientMotion && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                    .animation(.easeInOut(duration: 0.9), value: inputs.window?.usedPercent)
                HStack(alignment: .top, spacing: 16) {
                    // The waiting capsule sits under the conclusion, in the sky left of "now", which is otherwise empty.
                    VStack(alignment: .leading, spacing: 12) {
                        HorizonHeadlineView(inputs: inputs, store: store)
                        if !board.waiting.isEmpty {
                            WaitingCapsule(waiting: board.waiting, name: sessions.name(of:), actions: actions)
                        }
                    }
                    Spacer(minLength: 0)
                    SideNumber(inputs: inputs, store: store).fixedSize().padding(.top, 2)
                }
                .padding(.horizontal, 28).padding(.top, 8)
            }
            .frame(width: width, height: scene.layout.height * s)

            lanes(scene, scale: s)
            footer
        }
        .background(alignment: .bottom) {
            // The planet's night side carries on under the lanes and the footer.
            HorizonColor.ground.padding(.top, scene.layout.height * s - 1)
        }
        .overlay(alignment: .topTrailing) {
            if let id = focus, let lane = scene.lanes.first(where: { $0.id == id }) {
                SessionCard(session: lane.session, name: sessions.name(of: lane.session), context: sessions.context[id],
                            fraction: sessions.contextFraction(id), approval: sessions.approvals[id],
                            decide: { r, d in sessions.decide(r, d) }, actions: actions)
                    .id(id)
                    .frame(width: 318)
                    .onHover { inside in
                        hoveringCard = inside
                        if !inside { scheduleBlur() }
                    }
                    .padding(.trailing, 28).padding(.top, 84 * s)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: focus)
    }

    private func laneHover(_ id: String, _ inside: Bool) {
        if inside {
            hoveredLane = id
            focus = id
        } else {
            if hoveredLane == id { hoveredLane = nil }
            scheduleBlur()
        }
    }

    /// Leaves the card up long enough to move the pointer onto it.
    private func scheduleBlur() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if hoveredLane == nil && !hoveringCard { focus = nil }
        }
    }

    @ViewBuilder
    private func lanes(_ scene: HorizonScene, scale s: CGFloat) -> some View {
        if scene.lanes.isEmpty {
            ZStack(alignment: .leading) {
                LaneBackdrop(scene: scene, lane: nil, scale: s)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t(settings.sessionsEnabled ? "No agent sessions right now." : "Session tracking is off."))
                        .font(.system(size: 12)).foregroundStyle(HorizonColor.label)
                    if settings.sessionsEnabled, sessions.hookStatus == .notInstalled {
                        Text(L10n.t("Install the Claude Code hooks in Settings → Sessions to see them here."))
                            .font(.system(size: 11)).foregroundStyle(Theme.amber)
                    }
                }
                .padding(.leading, scene.layout.x(angle: scene.nowAngle) * s + 24)
            }
            .frame(height: Self.laneHeight)
        } else {
            ScrollView(.vertical, showsIndicators: lanesHeight > lanesMaxHeight) {
                VStack(spacing: 0) {
                    ForEach(scene.lanes) { lane in
                        LaneRow(scene: scene, lane: lane, scale: s, name: sessions.name(of: lane.session),
                                context: sessions.context[lane.id], fraction: sessions.contextFraction(lane.id),
                                approvable: sessions.approvals[lane.id] != nil, actions: actions, onHover: { laneHover(lane.id, $0) })
                            .frame(height: Self.laneHeight)
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                    }
                }
                // A session that starts waiting slides up to the top instead of jumping there.
                .animation(.spring(response: 0.45, dampingFraction: 0.86), value: scene.lanes.map { "\($0.id)|\($0.role)" })
                .background(GeometryReader { g in Color.clear.preference(key: LanesHeightKey.self, value: g.size.height) })
            }
            .frame(height: min(max(lanesHeight, Self.laneHeight), lanesMaxHeight))
            .onPreferenceChange(LanesHeightKey.self) { lanesHeight = $0 }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button(L10n.t("Refresh")) { actions?.refreshNow() }
            Button(L10n.t("Settings…")) { actions?.openSettings() }
            UpdateLink()
            Spacer()
            key(Theme.claude, L10n.t("Claude working"))
            key(Theme.codex, L10n.t("Codex working"))
            key(Theme.amber, L10n.t("Waiting on you"))
            key(Theme.done, L10n.t("Done"))
            HStack(spacing: 6) {
                Circle().stroke(Color.white.opacity(0.8), lineWidth: 2).frame(width: 9, height: 9)
                Text(L10n.t("Small ring = context used"))
            }
            .help(L10n.t("Context %% is an estimate (200k or 1M window)."))
            Button(L10n.t(pinned ? "Unpin" : "Pin")) { actions?.togglePinned() }
                .foregroundStyle(Color.white.opacity(0.78))
        }
        .buttonStyle(.plain)
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(HorizonColor.label)
        .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 14)
    }

    private func key(_ c: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(c).frame(width: 14, height: 6)
            Text(text)
        }
    }
}

private struct LanesHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Arc

/// The arc's layers, stacked. Animatable on the usage number, so a new reading slides the curve, the
/// current point and the forecast up to their new place instead of jumping.
struct HorizonArc: View, Animatable {
    let inputs: HorizonInputs
    let now: Date
    let board: SessionBoard
    var used: Double
    /// Breathing glow and flowing forecast on; off for Reduce Motion or by choice.
    var ambient = true

    var animatableData: Double {
        get { used }
        set { used = newValue }
    }

    var body: some View {
        let scene = HorizonScene(layout: .band, now: now, window: window(used), samples: inputs.samples,
                                 prediction: inputs.prediction, sessions: board)
        ZStack {
            HorizonCanvas(scene: scene, layer: .sky)
            // The lit stretch breathes slowly: usage is being spent. The blurred glow is rendered once into a
            // bitmap and only that bitmap's opacity animates; animating the Canvas itself redrew the blur every
            // frame (a quarter of a CPU core while the panel was open).
            GeometryReader { geo in
                let k = geo.size.width / scene.layout.width
                let box = glowBox(scene)
                if let image = glowImage(scene, size: geo.size, crop: box) {
                    Group {
                        if ambient { BreathingImage(image: image) } else { Image(nsImage: image).resizable() }
                    }
                    .frame(width: box.width * k, height: box.height * k)
                    .position(x: box.midX * k, y: box.midY * k)
                }
            }
            HorizonCanvas(scene: scene, layer: .main)
            if !ambient, let (from, to) = scene.forecast {
                // Still: the same dashes, not moving.
                GeometryReader { geo in
                    let k = geo.size.width / scene.layout.width
                    Path { p in p.move(to: CGPoint(x: from.x * k, y: from.y * k)); p.addLine(to: CGPoint(x: to.x * k, y: to.y * k)) }
                        .stroke(Theme.amber, style: StrokeStyle(lineWidth: 2 * k, dash: [5 * k, 5 * k]))
                }
            }
            // The forecast flows toward where it ends, a trend rather than a fixed line.
            if ambient, let (from, to) = scene.forecast {
                GeometryReader { geo in
                    let k = geo.size.width / scene.layout.width
                    FlowingDashes(points: [CGPoint(x: from.x * k, y: from.y * k), CGPoint(x: to.x * k, y: to.y * k)],
                                  color: NSColor(Theme.amber), lineWidth: 2 * k, dash: 5 * k)
                }
                .allowsHitTesting(false)
            }
        }
    }

    /// Where the glow is, in canvas units: the lit stretch and the sun, plus room for the blur.
    private func glowBox(_ scene: HorizonScene) -> CGRect {
        let L = scene.layout
        let pts = L.arc(from: scene.litFrom, to: scene.nowAngle, r: L.horizon, step: 1) + [scene.sun]
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let margin: CGFloat = 70    // half the 40-wide stroke plus three times the 16-point blur
        return CGRect(x: xs.min()! - margin, y: ys.min()! - margin,
                      width: xs.max()! - xs.min()! + 2 * margin, height: ys.max()! - ys.min()! + 2 * margin)
            .intersection(CGRect(x: 0, y: 0, width: L.width, height: L.height))
    }

    /// The glow layer rendered once into a bitmap, cropped to `crop` (canvas units).
    @MainActor
    private func glowImage(_ scene: HorizonScene, size: CGSize, crop: CGRect) -> NSImage? {
        guard size.width > 0, !crop.isEmpty else { return nil }
        let k = size.width / scene.layout.width
        let r = ImageRenderer(content: HorizonCanvas(scene: scene, layer: .glow).frame(width: size.width, height: size.height))
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        r.scale = scale
        guard let full = r.cgImage,
              let part = full.cropping(to: CGRect(x: crop.minX * k * scale, y: crop.minY * k * scale,
                                                  width: crop.width * k * scale, height: crop.height * k * scale)) else { return nil }
        return NSImage(cgImage: part, size: NSSize(width: crop.width * k, height: crop.height * k))
    }

    /// The window with `used` in place of its percentage, mid-animation.
    private func window(_ used: Double) -> UsageWindow? {
        guard let w = inputs.window else { return nil }
        return UsageWindow(key: w.key, label: w.label, kind: w.kind, usedPercent: used, resetsAt: w.resetsAt, duration: w.duration)
    }
}

/// Paints the quota on the horizon: lit stretch, usage curve, forecast, steady pace, reset, and "now".
/// Drawn as separate layers so the parts that move (the breathing glow; the flowing forecast is a Core
/// Animation layer of its own) never force the whole picture, with its blur, to be redrawn.
struct HorizonCanvas: View {
    enum Layer { case sky, glow, main }
    let scene: HorizonScene
    var layer: Layer = .main

    var body: some View {
        Canvas { ctx, size in
            let L = scene.layout
            ctx.scaleBy(x: size.width / L.width, y: size.width / L.width)
            switch layer {
            case .sky: drawSky(&ctx, L)
            case .glow: drawGlow(&ctx, L)
            case .main: draw(&ctx, L)
            }
        }
    }

    private func drawSky(_ ctx: inout GraphicsContext, _ L: HorizonLayout) {
        // Fades in from the panel's top so it sits on either background without a seam.
        ctx.fill(Path(CGRect(x: 0, y: 0, width: L.width, height: L.height)),
                 with: .linearGradient(Gradient(colors: [Color(hex: 0x05060C).opacity(0), Color(hex: 0x0B1428).opacity(0.9)]),
                                       startPoint: .zero, endPoint: CGPoint(x: 0, y: L.height)))
    }

    /// The lit stretch of horizon and the sun, blurred; sits under the planet.
    private func drawGlow(_ ctx: inout GraphicsContext, _ L: HorizonLayout) {
        let lit = L.arc(from: scene.litFrom, to: scene.nowAngle, r: L.horizon)
        let sun = scene.sun
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [Theme.claude, Theme.amber]), startPoint: L.point(scene.litFrom, L.horizon), endPoint: sun)
        ctx.addFilter(.blur(radius: 16))
        ctx.opacity = 0.75
        ctx.stroke(line(lit), with: shading, style: StrokeStyle(lineWidth: 40, lineCap: .round))
        ctx.fill(Path(ellipseIn: CGRect(x: sun.x - 26, y: sun.y - 26, width: 52, height: 52)), with: .color(Color(hex: 0xFFE2B0).opacity(0.9)))
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
        let nowX = L.x(angle: now)

        // No-quota stretch and the 100% line.
        let top = scene.hundredRadius
        if let a = scene.dryFrom, let b = scene.dryTo, b > a {
            var sector = line(L.arc(from: a, to: b, r: top))
            sector.addLines(L.arc(from: b, to: a, r: H))
            sector.closeSubpath()
            ctx.fill(sector, with: .color(Theme.amber.opacity(0.14)))
        }
        if scene.window != nil {
            ctx.stroke(line(L.arc(from: scene.litFrom, to: scene.dryFrom ?? L.maxAngle, r: top)), with: .color(.white.opacity(0.14)), lineWidth: 1)
            if let a = scene.dryFrom, let b = scene.dryTo, b > a {
                ctx.stroke(line(L.arc(from: a, to: b, r: top)), with: .color(Theme.amber), style: StrokeStyle(lineWidth: 2, dash: [5, 5]))
            }
            label(&ctx, "100%", at: L.point(scene.litFrom, top + 6), anchor: .bottomLeading)
        }

        // The glow of the lit stretch is its own layer (see `drawGlow`), underneath this one.
        let lit = L.arc(from: scene.litFrom, to: now, r: H)
        let sun = scene.sun
        let litShading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [Theme.claude, Theme.amber]), startPoint: L.point(scene.litFrom, H), endPoint: sun)

        // The planet; its night side continues under the panel as the lanes' ground.
        let c = L.center
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - H, y: c.y - H, width: 2 * H, height: 2 * H)),
                 with: .linearGradient(Gradient(colors: [Color(hex: 0x080B18), HorizonColor.ground]),
                                       startPoint: CGPoint(x: 0, y: L.point(0, H).y), endPoint: CGPoint(x: 0, y: L.height)))

        // Usage so far, filled down to the horizon.
        if scene.curve.count >= 2, let first = scene.curve.first {
            var area = line(scene.curve)
            area.addLines(L.arc(from: now, to: atan2(first.x - c.x, c.y - first.y) * 180 / .pi, r: H))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(Gradient(colors: [HorizonColor.claudeBright.opacity(0.55), Theme.claude.opacity(0.10)]),
                                                 startPoint: CGPoint(x: 0, y: L.point(now, top).y), endPoint: CGPoint(x: 0, y: sun.y)))
            ctx.stroke(line(scene.curve), with: .color(HorizonColor.claudeBright),
                       style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }

        if scene.paceLine.count >= 2 {
            ctx.stroke(line(scene.paceLine), with: .color(.white.opacity(0.22)), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            // Label it where nothing else is written: right of "now" and clear of the no-quota stretch.
            let order = scene.paceLine.indices.sorted { abs($0 - scene.paceLine.count / 2) < abs($1 - scene.paceLine.count / 2) }
            let spot = order.map { scene.paceLine[$0] }.first { p in
                let a = atan2(p.x - c.x, c.y - p.y) * 180 / .pi
                let inDry = scene.dryFrom.map { from in a > from - 3 && a < (scene.dryTo ?? from) + 3 } ?? false
                return p.x > nowX + 60 && p.x < L.width - 60 && !inDry
            }
            if let p = spot { label(&ctx, L10n.t("Steady pace"), at: CGPoint(x: p.x, y: p.y + 8), anchor: .top) }
        }

        // Forecast.
        // The dashed line itself flows on a Core Animation layer (`FlowingDashes`); the end point and words stay here.
        if let (_, to) = scene.forecast {
            if let at = scene.exhaustAt, scene.dryFrom != nil {
                ctx.fill(Path(ellipseIn: CGRect(x: to.x - 5, y: to.y - 5, width: 10, height: 10)), with: .color(Theme.amber))
                label(&ctx, Formatting.clock(at), at: CGPoint(x: to.x, y: to.y - 9), anchor: .bottom, size: 11.5, weight: .bold, color: Theme.amber)
                if let a = scene.dryFrom, let b = scene.dryTo, let reset = scene.window?.resetsAt {
                    label(&ctx, L10n.f("No quota here, about %@", Formatting.countdown(reset.timeIntervalSince(at))),
                          at: L.point((a + b) / 2, (H + top) / 2 + 8), size: 10.5, color: .white.opacity(0.78))
                }
            }
        }

        // Horizon line, brighter where the window has been lit.
        ctx.stroke(line(L.arc(from: L.minAngle - 6, to: scene.litFrom, r: H)), with: .color(.white.opacity(0.18)), lineWidth: 2)
        ctx.stroke(line(L.arc(from: now, to: L.maxAngle + 6, r: H)), with: .color(.white.opacity(0.18)), lineWidth: 2)
        if scene.window != nil {
            ctx.stroke(line(lit), with: litShading, style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }

        // Time ticks, with faint guides dropping into the lanes on the past side.
        for t in scene.ticks {
            let p = L.point(t.angle, H)
            ctx.stroke(line([p, L.point(t.angle, H - 8)]), with: .color(.white.opacity(0.4)), lineWidth: 1)
            if t.kind == .hour, p.x < nowX - 4 {
                ctx.stroke(line([CGPoint(x: p.x, y: p.y + 26), CGPoint(x: p.x, y: L.height)]), with: .color(.white.opacity(0.06)), lineWidth: 1)
            }
            let text: String
            switch t.kind {
            case .hour: text = Formatting.clock(t.date)
            case .windowStart: text = L10n.f("%@ start", Formatting.clock(t.date))
            case .reset: text = L10n.f("%@ reset", Formatting.clock(t.date))
            }
            label(&ctx, text, at: L.point(t.angle, H - 18))
        }

        // "Now": straight down from its label, through the sun, on into the lanes.
        let pill = ctx.resolve(Text(L10n.f("Now %@", Formatting.clock(scene.clock.now)))
            .font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundColor(.black))
        let ts = pill.measure(in: CGSize(width: 200, height: 40))
        let box = CGRect(x: nowX - ts.width / 2 - 7, y: 116, width: ts.width + 14, height: 16)
        ctx.stroke(line([CGPoint(x: nowX, y: box.maxY), CGPoint(x: nowX, y: L.height)]), with: .color(HorizonColor.nowLine), lineWidth: 1.5)
        ctx.fill(Path(roundedRect: box, cornerRadius: 8), with: .color(.white))
        ctx.draw(pill, at: CGPoint(x: box.midX, y: box.midY))
        ctx.fill(Path(ellipseIn: CGRect(x: sun.x - 7, y: sun.y - 7, width: 14, height: 14)), with: .color(.white))
        if let cur = scene.current, let w = scene.window {
            let dot = CGRect(x: cur.x - 5, y: cur.y - 5, width: 10, height: 10)
            ctx.fill(Path(ellipseIn: dot), with: .color(HorizonColor.claudeBright))
            ctx.stroke(Path(ellipseIn: dot), with: .color(.white), lineWidth: 1.5)
            label(&ctx, L10n.f("Used %d%%", Int(w.usedPercent.rounded())), at: CGPoint(x: cur.x - 10, y: cur.y - 6),
                  anchor: .bottomTrailing, size: 10.5, weight: .semibold, color: HorizonColor.claudeBright)
        }
    }
}

// MARK: - Lanes

/// The drawn part of a lane: its track, its working/waiting stretches, the hour guides and the "now" line.
struct LaneBackdrop: View {
    let scene: HorizonScene
    let lane: HorizonLane?
    /// Panel points per canvas unit, the same scale the arc above is drawn at.
    let scale: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let L = scene.layout
            func x(_ angle: Double) -> CGFloat { L.x(angle: angle) * scale }
            func bar(_ a: CGFloat, _ b: CGFloat, y: CGFloat) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: a, y: y))
                p.addLine(to: CGPoint(x: b, y: y))
                return p
            }
            let nowX = x(scene.nowAngle)
            let y = size.height / 2
            for t in scene.ticks where t.kind == .hour && x(t.angle) < nowX - 4 {
                var p = Path()
                p.move(to: CGPoint(x: x(t.angle), y: 0))
                p.addLine(to: CGPoint(x: x(t.angle), y: size.height))
                ctx.stroke(p, with: .color(.white.opacity(0.06)), lineWidth: 1)
            }
            if let lane {
                ctx.stroke(bar(x(L.minAngle), nowX, y: y), with: .color(.white.opacity(0.06)), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                for seg in lane.segments {
                    let p = bar(x(seg.from), x(seg.to), y: y)
                    let color: Color = lane.role == .idle ? .white.opacity(0.25)
                        : seg.kind == .waiting ? Theme.amber : Theme.accent(lane.session.provider)
                    ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    if seg.kind == .waiting, lane.role != .idle {
                        // A white core tells waiting apart from Claude's similar orange.
                        ctx.stroke(p, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    }
                }
            }
            var now = Path()
            now.move(to: CGPoint(x: nowX, y: 0))
            now.addLine(to: CGPoint(x: nowX, y: size.height))
            ctx.stroke(now, with: .color(HorizonColor.nowLine), lineWidth: 1.5)
        }
    }
}

/// One session: past on the left, its light on the "now" line, and in words what it is doing.
struct LaneRow: View {
    let scene: HorizonScene
    let lane: HorizonLane
    let scale: CGFloat
    let name: String
    let context: Int?
    /// Context used, 0...1: reported by the status line when installed, else estimated from `context`.
    let fraction: Double?
    /// A permission request can be answered from this lane's card.
    var approvable = false
    weak var actions: AppActions?
    var onHover: (Bool) -> Void = { _ in }
    @State private var hovered = false

    var body: some View {
        let s = lane.session
        let waiting = lane.role == .waiting
        let nowX = scene.layout.x(angle: scene.nowAngle) * scale
        Button { actions?.jump(to: s) } label: {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(waiting ? Theme.amber.opacity(hovered ? 0.14 : 0.08)
                          : lane.role == .done ? Theme.done.opacity(hovered ? 0.12 : 0.06) : Color.white.opacity(hovered ? 0.06 : 0))
                    .padding(.horizontal, 12).padding(.vertical, 2)
                LaneBackdrop(scene: scene, lane: lane, scale: scale)
                SessionLight(lane: lane, context: fraction)
                    .position(x: nowX, y: HorizonPanel.laneHeight / 2)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(name)
                            .font(.system(size: 13, weight: waiting ? .semibold : .medium))
                            .foregroundStyle(Color.white.opacity(lane.role == .idle ? 0.6 : 0.95))
                        Spacer(minLength: 8)
                        if approvable {
                            Text(L10n.t("Approve here"))
                                .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.amber)
                                .padding(.horizontal, 7).padding(.vertical, 1)
                                .overlay(Capsule().stroke(Theme.amber.opacity(0.7), lineWidth: 1))
                                .fixedSize()
                        }
                        SessionBadge(session: s, done: lane.role == .done)
                    }
                    HStack(spacing: 8) {
                        Text(doing(s))
                            .font(waiting ? .system(size: 11, design: .monospaced) : .system(size: 11))
                            .foregroundStyle(waiting ? Theme.amber.opacity(0.9) : Theme.dim)
                        Spacer(minLength: 8)
                        SessionMeta(session: s, context: fraction)
                    }
                }
                .lineLimit(1)
                .padding(.leading, nowX + 24).padding(.trailing, 28)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0; onHover($0) }
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

/// One session's light: a context ring around a coloured core, an amber halo when it needs you.
/// News gets one gesture: a session that has just started waiting sends out ripples; one that has just
/// finished pops in its check mark. Old news only keeps the steady pulse.
struct SessionLight: View {
    let lane: HorizonLane
    let context: Double?
    /// Bumped to send out a ripple.
    @State private var ripples = 0
    @State private var popped = true

    /// A wait or finish this recent still counts as news when the panel opens on it.
    static let fresh: TimeInterval = 30

    var body: some View {
        let color = HorizonColor.dot(lane)
        ZStack {
            if lane.role == .waiting {
                // Both on Core Animation: as SwiftUI repeating animations they kept the app busy for as long as
                // anyone waited, even with the panel closed.
                PulsingCircle(diameter: 22, color: NSColor(Theme.amber), lineWidth: 2, scale: (1, 2.8), opacity: (0.9, 0),
                              period: 1.0, autoreverses: false, repeats: ripples > 0 ? 3 : 0, trigger: ripples, fps: 30)
                    .frame(width: 64, height: 64)
                PulsingCircle(diameter: 34, color: NSColor(Theme.amber.opacity(0.45)), lineWidth: 1.5)
                    .frame(width: 40, height: 40)
                Circle().fill(Theme.amber.opacity(0.6)).frame(width: 24, height: 24).blur(radius: 5)
            }
            if lane.role == .done {
                Circle().fill(color.opacity(0.55)).frame(width: 22, height: 22).blur(radius: 5)
                Circle().fill(color).frame(width: 15, height: 15)
                Image(systemName: "checkmark").font(.system(size: 8, weight: .black)).foregroundStyle(HorizonColor.ground)
            } else if lane.session.provider == .codex || context == nil {
                if lane.role != .idle { Circle().fill(color.opacity(0.6)).frame(width: 16, height: 16).blur(radius: 4) }
                Circle().fill(color).frame(width: 11, height: 11)
            } else {
                Circle().fill(HorizonColor.ground).frame(width: 22, height: 22)
                Circle().stroke(Color.white.opacity(0.2), lineWidth: 3).frame(width: 22, height: 22)
                Circle().trim(from: 0, to: context ?? 0)
                    .stroke(Color.white.opacity(lane.role == .idle ? 0.5 : 1), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 22, height: 22)
                Circle().fill(color).frame(width: 11, height: 11)
            }
        }
        .scaleEffect(popped ? 1 : 0.3)
        .frame(width: 40, height: 40)
        .onAppear { react(isNews: Date().timeIntervalSince(lane.session.stateSince) < Self.fresh) }
        .onChange(of: lane.role) { _, _ in react(isNews: true) }
    }

    private func react(isNews: Bool) {
        switch lane.role {
        case .waiting:
            if isNews { ripples += 1 }
        case .done:
            if isNews {
                popped = false
                withAnimation(.spring(response: 0.38, dampingFraction: 0.45)) { popped = true }
            }
        case .working, .idle:
            break
        }
    }
}

// MARK: - Waiting and details

/// "Needs you 2" with one button per waiting session; a click jumps to its terminal.
struct WaitingCapsule: View {
    let waiting: [AgentSession]
    let name: (AgentSession) -> String
    weak var actions: AppActions?

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.amber).frame(width: 8, height: 8).shadow(color: Theme.amber.opacity(0.9), radius: 4)
            Text(L10n.f("Needs you %d", waiting.count))
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.amber).fixedSize()
            ForEach(waiting.prefix(2)) { s in
                Button { actions?.jump(to: s) } label: {
                    Text(SessionText.short(name(s)) + " ›")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        .padding(.horizontal, 11).frame(height: 26)
                        .background(Capsule().fill(Theme.amber.opacity(0.22)))
                }
                .buttonStyle(.plain)
                .help(s.waitingMessage ?? s.cwd)
            }
            if waiting.count > 2 {
                Text("+\(waiting.count - 2)").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.amber)
            }
        }
        .padding(.leading, 14).padding(.trailing, 7)
        .frame(height: 38)
        .background(Capsule().fill(Theme.amber.opacity(0.16)))
        .fixedSize()
    }
}

/// Details for one session; appears while its lane (or the card itself) is hovered.
struct SessionCard: View {
    let session: AgentSession
    let name: String
    let context: Int?
    let fraction: Double?
    var approval: ApprovalRequest?
    var decide: (ApprovalRequest, ApprovalDecision) -> Bool = { _, _ in false }
    /// The answer just given from this card, kept on screen for a moment so the click is visibly taken.
    @State private var answered: (decision: ApprovalDecision, reached: Bool)?
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
                        .fixedSize()
                }
            }
            if let a = answered {
                answeredBlock(a.decision, reached: a.reached)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else if let r = approval {
                approvalBlock(r)
            } else if let m = s.waitingMessage {
                row(L10n.t("Requesting"), m, mono: true)
            }
            if let p = s.promptPreview, !p.isEmpty { row(L10n.t("Prompt"), p) }
            if let recent = s.recent, !recent.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(recent.enumerated()), id: \.offset) { _, a in row(SessionText.ago(a.at), a.text) }
                }
            }
            if let f = fraction {
                HStack(spacing: 10) {
                    Text(L10n.t("Context")).font(.system(size: 11)).foregroundStyle(HorizonColor.label).frame(width: 52, alignment: .leading)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.12))
                            Capsule().fill(Color.white.opacity(0.75)).frame(width: g.size.width * f)
                        }
                    }
                    .frame(height: 4)
                    Text("\(Int((f * 100).rounded()))%" + (context.map { " · " + TranscriptReader.short($0) } ?? ""))
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.86)).fixedSize()
                }
                .help(L10n.t("Context %% is an estimate (200k or 1M window)."))
            }
            row(L10n.t("Folder"), (s.cwd as NSString).abbreviatingWithTildeInPath)
            Button { actions?.jump(to: s) } label: {
                Text(AppNames.jumpLabel(s))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 16).frame(height: 30)
                    .background(Capsule().fill(Color.white))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0x12141B).opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(s.state.needsYou ? Theme.amber.opacity(0.45) : Color.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
    }

    /// The whole request, untruncated, and the only two answers on offer.
    private func approvalBlock(_ r: ApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(r.tool).font(.system(size: 11, weight: .semibold)).foregroundStyle(HorizonColor.label)
            ScrollView {
                Text(r.full)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.45)))
            HStack(spacing: 8) {
                Button { answer(r, .allow) } label: {
                    Text(L10n.t("Allow once")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 14).frame(height: 28).background(Capsule().fill(Theme.amber))
                }
                Button { answer(r, .deny) } label: {
                    Text(L10n.t("Deny")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 28).background(Capsule().stroke(Color.white.opacity(0.5)))
                }
                Spacer(minLength: 4)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(L10n.f("Terminal asks in %d s", max(0, Int(r.expires.timeIntervalSince(ctx.date).rounded()))))
                        .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(HorizonColor.label)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func answer(_ r: ApprovalRequest, _ d: ApprovalDecision) {
        let reached = decide(r, d)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { answered = (d, reached) }
    }

    /// "Allowed: Claude carries on" / "Denied" / "Too late: answer in the terminal".
    private func answeredBlock(_ d: ApprovalDecision, reached: Bool) -> some View {
        let agent = session.provider.displayName
        let (icon, color, text): (String, Color, String) =
            !reached ? ("exclamationmark.circle.fill", Theme.amber, L10n.t("Too late: the terminal is already asking. Answer it there."))
            : d == .allow ? ("checkmark.circle.fill", Color(red: 0.30, green: 0.80, blue: 0.45), L10n.f("Allowed. %@ carries on.", agent))
            : ("xmark.circle.fill", Color.white.opacity(0.7), L10n.f("Denied. %@ was told no.", agent))
        return HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(color)
            Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
        }
        .padding(.horizontal, 12).frame(height: 36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.16)))
    }

    private func row(_ key: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(key).font(.system(size: 11)).foregroundStyle(HorizonColor.label).frame(width: 52, alignment: .leading)
            Text(value).font(mono ? .system(size: 11, design: .monospaced) : .system(size: 11))
                .foregroundStyle(.white.opacity(0.86)).lineLimit(2)
        }
    }
}

// MARK: - Corner text

/// The conclusion first, then the numbers behind it.
struct HorizonHeadlineView: View {
    let inputs: HorizonInputs
    @ObservedObject var store: UsageStore

    var body: some View {
        let h = HorizonHeadline(provider: inputs.main, window: inputs.window, prediction: inputs.prediction)
        let status = store.status[inputs.main] ?? .idle
        let color: Color = switch h.tone {
        case .warning: Theme.amber
        case .fine: inputs.main == .claude ? HorizonColor.claudeBright : HorizonColor.codexBright
        case .unknown: .white.opacity(0.9)
        }
        VStack(alignment: .leading, spacing: 3) {
            Text(h.title)
                .contentTransition(.numericText())
                .animation(.snappy, value: h.title)
                .font(.system(size: h.tone == .warning ? 32 : 24, weight: .bold).monospacedDigit())
                .foregroundStyle(color)
            if let sub = h.subtitle {
                Text(sub).font(.system(size: 12.5).monospacedDigit()).foregroundStyle(.white.opacity(0.86))
            }
            if let d = h.detail {
                Text(d).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(HorizonColor.label)
            }
            if inputs.window == nil || status.message != nil {
                Text(placeholder(status)).font(.system(size: 11))
                    .foregroundStyle(status.message == nil ? HorizonColor.label : Theme.amber).lineLimit(2)
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

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if let side = inputs.side, let w = store.snapshots[side]?.primary {
                let h = HorizonHeadline(provider: side, window: w, prediction: store.predictions[side])
                Text(Formatting.percent(w.usedPercent))
                    .contentTransition(.numericText(value: w.usedPercent))
                    .animation(.snappy, value: Int(w.usedPercent.rounded()))
                    .font(.system(size: 26, weight: .bold).monospacedDigit())
                    .foregroundStyle(h.tone == .warning ? Theme.amber : (side == .codex ? HorizonColor.codexBright : HorizonColor.claudeBright))
                Text(side.displayName + " " + HorizonHeadline.windowName(w) + " · " + h.title)
                    .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(h.tone == .warning ? Theme.amber : .white.opacity(0.78))
            } else if let side = inputs.side {
                Text(side.displayName + " —").font(.system(size: 11.5)).foregroundStyle(HorizonColor.label)
            }
            ForEach(weeklyLines, id: \.text) { line in
                Text(line.text).font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(line.warning ? Theme.amber : HorizonColor.label)
            }
        }
        .lineLimit(1)
    }

    /// The main provider's weekly windows other than the one on the horizon: the general weekly always,
    /// per-model weeklies only when they would run out before their reset.
    private var weeklyLines: [(text: String, warning: Bool)] {
        guard let snap = store.snapshots[inputs.main] else { return [] }
        let forecasts = store.weeklyForecasts[inputs.main] ?? [:]
        return snap.windows.compactMap { w in
            guard w.key != inputs.window?.key, (w.duration ?? 0) >= Predictor.longWindow, w.key != "extra_usage" else { return nil }
            let p = forecasts[w.key]
            let warning = p?.exhaustsBeforeReset == true
            guard w.kind == .sevenDay || warning else { return nil }
            var text = inputs.main.displayName + " " + HorizonHeadline.windowName(w) + " " + Formatting.percent(w.usedPercent)
            if warning, let at = p?.exhaustAt { text += " · " + L10n.f("runs out %@", HorizonHeadline.when(at, now: Date())) }
            return (text, warning)
        }
    }
}
