import AppKit
import SwiftUI
import AureoleCore

/// What decides how the sky looks; a change of either eases in.
struct SkyState: Equatable {
    var sky: SkyPalette?
    var moving: Bool
}

/// The stars that finished tasks have left in the sky since the app started.
@MainActor
enum FallenStars {
    /// One finish: the session and when it finished, so a session that finishes twice leaves two.
    struct Entry {
        var key: String
        /// Which place in the sky it took; never reused, so stars stay where they fell.
        var slot: Int
    }

    private(set) static var all: [Entry] = []
    private static var slots = 0
    static let most = 24

    static func has(_ key: String) -> Bool { all.contains { $0.key == key } }

    static func add(_ key: String) -> Entry {
        let e = Entry(key: key, slot: slots)
        slots += 1
        all.append(e)
        if all.count > most { all.removeFirst(all.count - most) }
        return e
    }

    /// Where a star lands, in the arc canvas's units: the open sky between the headline and the numbers on the
    /// right, above the 100% line, with room for the meteor to come in from the upper right without crossing
    /// either. The first lands where the sample film's did.
    static func landing(_ slot: Int) -> CGPoint {
        func frac(_ x: Double) -> Double { x - x.rounded(.down) }
        return CGPoint(x: 450 + 200 * frac(0.49 + Double(slot) * 0.618), y: 36 + 48 * frac(0.5834 + Double(slot) * 0.382))
    }
}

/// The sky's own motion, on Core Animation layers above the still sky: one star in three twinkles, the planet's
/// edge breathes, a light slides along it now and then, and a finished task drops a meteor that leaves a star.
/// The window server runs all of it; the app draws nothing per frame. With `moving` off (old numbers, Reduce
/// Motion, or by choice) the layers fade out and the still sky underneath shows everything at rest.
struct SkyMotion: NSViewRepresentable {
    /// Seconds one mood takes to become the next, and the sky to start or stop moving.
    static let fade = 1.6

    let scene: HorizonScene
    let sky: SkyPalette
    let moving: Bool
    /// Sessions showing as finished, and since when.
    let done: [String: Date]

    func makeNSView(context: Context) -> SkyMotionView { SkyMotionView() }

    func updateNSView(_ v: SkyMotionView, context: Context) {
        v.show(scene: scene, sky: sky, moving: moving, done: done)
    }

    static func dismantleNSView(_ v: SkyMotionView, coordinator: ()) { v.stop() }
}

final class SkyMotionView: NSView {
    override var isFlipped: Bool { true }

    /// `AUREOLE_SKY_POSE=<light>,<meteor>` holds the moving sky still at one instant, for a snapshot to check the
    /// layers against the sample film: the sliding light that far along the edge (0…1), a meteor that far along
    /// its fall, the stars and the breath at their brightest. Nothing animates.
    static let pose: (glint: Double, meteor: Double)? = {
        guard let raw = ProcessInfo.processInfo.environment["AUREOLE_SKY_POSE"] else { return nil }
        let p = raw.split(separator: ",").compactMap { Double($0) }
        return p.count == 2 ? (p[0], p[1]) : nil
    }()

    /// Everything that moves by itself; fades out when the sky comes to rest.
    private let field = CALayer()
    private let breath = CALayer()
    private let starField = CALayer()
    /// Turns about the planet's centre, carrying the sliding light along the edge.
    private let glintArm = CALayer()
    private let glint = CALayer()
    /// Meteors and the stars they leave; these stay when the rest stops.
    private let fallen = CALayer()

    private var scene: HorizonScene?
    private var layout_ = HorizonLayout.band
    private var sun = CGPoint.zero
    private var sky = SkyPalette.zero
    private var moving = false
    private var done: [String: Date] = [:]

    /// What the layers were last built for.
    private var built: (size: CGSize, sun: CGPoint, sky: SkyPalette)?
    /// True once the panel's first look has been laid out: from then on, changes ease in.
    private var settled = false
    private var running = false
    private var stars: [(layer: CAShapeLayer, star: HorizonCanvas.Star)] = []
    private var glintTimer: Timer?
    /// Finishes already answered with a meteor or a quiet star; nil until the panel's first look.
    private var answered: Set<String>?
    private var fallenShown: Set<String> = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        field.opacity = 0
        glintArm.opacity = 0
        for l in [breath, starField, glintArm] { field.addSublayer(l) }
        glintArm.addSublayer(glint)
        layer?.addSublayer(field)
        layer?.addSublayer(fallen)
        startTrace()
        startBlink()
    }

    /// `AUREOLE_SKY_BLINK=<seconds>,<file>` stops the motion and starts it again every that many seconds, writing
    /// the clock time of each change to the file: for measuring what the motion costs, on against off, with
    /// everything else on the screen the same.
    private func startBlink() {
        guard let raw = ProcessInfo.processInfo.environment["AUREOLE_SKY_BLINK"] else { return }
        let parts = raw.split(separator: ",", maxSplits: 1).map(String.init)
        guard parts.count == 2, let every = Double(parts[0]) else { return }
        FileManager.default.createFile(atPath: parts[1], contents: nil)
        let timer = Timer(timeInterval: every, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window != nil, self.moving, let out = FileHandle(forWritingAtPath: parts[1]) else { return }
                self.setRunning(!self.running, eased: false)
                out.seekToEndOfFile()
                out.write("\(Date().timeIntervalSince1970) \(self.running ? "on" : "off")\n".data(using: .utf8)!)
                try? out.close()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// `AUREOLE_SKY_TRACE=<file>` writes, twice a second, where the window server has the moving layers right now
    /// (their presentation values): a way to check on the real screen that everything runs, without a recording.
    private func startTrace() {
        guard let path = ProcessInfo.processInfo.environment["AUREOLE_SKY_TRACE"] else { return }
        let began = Self.traceBegan
        Self.traceViews += 1
        let tag = Self.traceViews
        if tag == 1 { FileManager.default.createFile(atPath: path, contents: nil) }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window != nil, let out = FileHandle(forWritingAtPath: path) else { return }
                func f(_ v: Any?) -> String { (v as? NSNumber).map { String(format: "%.2f", $0.doubleValue) } ?? "-" }
                let star = self.stars.first?.layer.presentation()
                let turn = (self.glintArm.presentation()?.value(forKeyPath: "transform.rotation.z") as? NSNumber).map { $0.doubleValue * 180 / .pi }
                let meteor = self.fallen.sublayers?.first { $0.animation(forKey: "fall") != nil }?.presentation()
                let line = String(format: "%5.1f #%d", CACurrentMediaTime() - began, tag)
                    + " moving=\(self.running) field=" + f(self.field.presentation()?.opacity)
                    + " breath=" + f(self.breath.presentation()?.opacity)
                    + " star0=" + f(star?.opacity) + "x" + f(star?.value(forKeyPath: "transform.scale"))
                    + " light=" + f(self.glintArm.presentation()?.opacity) + "@" + (turn.map { String(format: "%.1f°", $0) } ?? "-")
                    + " meteor=" + (meteor.map { String(format: "(%.0f,%.0f) a=%.2f", $0.position.x, $0.position.y, $0.opacity) } ?? "-")
                    + " stars=\(self.stars.count) fallen=\(self.fallenShown.count)\n"
                out.seekToEndOfFile()
                out.write(line.data(using: .utf8)!)
                try? out.close()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(scene: HorizonScene, sky: SkyPalette, moving: Bool, done: [String: Date]) {
        (self.scene, self.layout_, self.sun, self.sky, self.moving, self.done) = (scene, scene.layout, scene.sun, sky, moving, done)
        refresh()
    }

    override func layout() {
        super.layout()
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() } else { refresh() }
    }

    /// Ends everything that repeats; the view is going away.
    func stop() {
        glintTimer?.invalidate()
        glintTimer = nil
        running = false
        for l in [field, breath, glintArm] { l.removeAllAnimations() }
        for s in stars { s.layer.removeAllAnimations() }
    }

    private var k: CGFloat { bounds.width / layout_.width }
    private var pixels: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    private func refresh() {
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
        if built?.size != bounds.size || built?.sun != sun || built?.sky != sky {
            // Same place, new colours: the mood changed, and one sky fades into the other.
            let recolour = built.map { $0.size == bounds.size && $0.sun == sun } ?? false
            build(recolour: recolour)
            built = (bounds.size, sun, sky)
        }
        if !settled || ProcessInfo.processInfo.environment["AUREOLE_SKY_BLINK"] == nil || !moving { setRunning(moving) }
        answer()
        settled = true
    }

    // MARK: Building

    private func build(recolour: Bool) {
        let L = layout_, k = k
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [field, breath, starField, fallen] { l.frame = bounds }
        breath.contents = picture(.breath, crop: CGRect(x: 0, y: 0, width: L.width, height: L.height))
        breath.contentsGravity = .resize
        // The sliding light, drawn at the top of the arc and hung from the planet's centre.
        let rise = HorizonCanvas.glintRise + 4, reach = HorizonCanvas.glintReach + 4
        let top = L.center.y - L.horizon
        let box = CGRect(x: L.center.x - reach, y: top - rise, width: 2 * reach, height: rise + 12)
        glint.contents = picture(.glint, crop: box)
        glint.contentsGravity = .resize
        glint.bounds = CGRect(x: 0, y: 0, width: box.width * k, height: box.height * k)
        glint.position = CGPoint(x: (box.midX - L.center.x) * k, y: (box.midY - L.center.y) * k)
        glintArm.bounds = .zero
        glintArm.position = CGPoint(x: L.center.x * k, y: L.center.y * k)
        if recolour {
            for l in [breath, glint] {
                let t = CATransition()
                t.type = .fade
                t.duration = SkyMotion.fade
                t.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                l.add(t, forKey: "recolour")
            }
        } else {
            placeStars()
            placeFallen()
        }
        CATransaction.commit()
        if !recolour, running {
            // Laid out anew (the panel changed size): start the motion again on the new layers.
            running = false
            setRunning(true, eased: false)
        }
    }

    /// One of the canvas's sky layers as a bitmap, cropped to `crop` (canvas units).
    private func picture(_ which: HorizonCanvas.Layer, crop: CGRect) -> CGImage? {
        guard let scene else { return nil }
        let L = layout_
        let size = CGSize(width: bounds.width, height: bounds.width * L.height / L.width)
        let r = ImageRenderer(content: HorizonCanvas(scene: scene, layer: which, sky: sky).frame(width: size.width, height: size.height))
        r.scale = pixels
        let f = k * pixels
        return r.cgImage?.cropping(to: CGRect(x: crop.minX * f, y: crop.minY * f, width: crop.width * f, height: crop.height * f).integral)
    }

    private func placeStars() {
        let k = k
        for s in stars { s.layer.removeFromSuperlayer() }
        stars = HorizonCanvas.stars(layout_, sun: sun, starlight: sky.starlight).filter { $0.twinkles && $0.a > 0.03 }.map { star in
            let dot = Self.dot(radius: star.r * k, room: 1.4, scale: pixels)
            dot.position = CGPoint(x: star.at.x * k, y: star.at.y * k)
            dot.opacity = Float(star.a)
            starField.addSublayer(dot)
            return (dot, star)
        }
    }

    /// A white disc on a layer with room to grow `room` times without being cut off.
    private static func dot(radius: CGFloat, room: CGFloat, scale: CGFloat) -> CAShapeLayer {
        let side = 2 * radius * room + 2
        let dot = CAShapeLayer()
        dot.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        dot.path = CGPath(ellipseIn: CGRect(x: side / 2 - radius, y: side / 2 - radius, width: 2 * radius, height: 2 * radius), transform: nil)
        dot.fillColor = NSColor.white.cgColor
        dot.contentsScale = scale
        return dot
    }

    // MARK: Motion

    private func setRunning(_ on: Bool, eased: Bool = true) {
        guard on != running else { return }
        running = on
        // The panel opening on a moving sky shows it moving at once; only a change while it is open eases.
        let ease = eased && settled
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if ease {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = field.presentation()?.opacity ?? field.opacity
            a.toValue = on ? 1 : 0
            a.duration = SkyMotion.fade
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            field.add(a, forKey: "show")
        }
        field.opacity = on ? 1 : 0
        CATransaction.commit()
        if on, let pose = Self.pose {
            hold(pose.glint)
        } else if on {
            startBreath()
            startTwinkle()
            glintTimer?.invalidate()
            // The first light soon after the sky starts moving, then one every nine seconds.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, self.running, self.glintTimer == nil else { return }
                self.slideGlint()
                let timer = Timer(timeInterval: 9, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.slideGlint() }
                }
                timer.tolerance = 0.5
                RunLoop.main.add(timer, forMode: .common)
                self.glintTimer = timer
            }
        } else {
            glintTimer?.invalidate()
            glintTimer = nil
            // Let the fade finish on moving layers, then leave nothing running.
            DispatchQueue.main.asyncAfter(deadline: .now() + (ease ? SkyMotion.fade : 0)) { [weak self] in
                guard let self, !self.running else { return }
                self.breath.removeAllAnimations()
                self.glintArm.removeAllAnimations()
                for s in self.stars { s.layer.removeAllAnimations() }
            }
        }
    }

    private static let traceBegan = CACurrentMediaTime()
    private static var traceViews = 0

    /// The instant a pose asks for, as the layers' own values.
    private func hold(_ glintAlong: Double) {
        let L = layout_
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (dot, star) in stars {
            dot.opacity = Float(star.a)
            dot.setAffineTransform(CGAffineTransform(scaleX: 1.35, y: 1.35))
        }
        let eased = glintAlong * glintAlong * (3 - 2 * glintAlong)
        glintArm.setAffineTransform(CGAffineTransform(rotationAngle: (L.minAngle - 3 + (L.maxAngle - L.minAngle + 6) * eased) * .pi / 180))
        glintArm.opacity = Float(sin(.pi * glintAlong))
        CATransaction.commit()
    }

    /// The edge's light and the sun's swell and fade together, once in seven seconds.
    private func startBreath() {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0
        a.toValue = 1
        a.duration = 3.5
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // A seven-second swell needs few frames; every frame is a recomposite of the panel.
        a.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 12, preferred: 10)
        breath.add(a, forKey: "breathe")
    }

    private func startTwinkle() {
        for (dot, star) in stars {
            let o = CABasicAnimation(keyPath: "opacity")
            o.fromValue = 0.25 * star.a
            o.toValue = star.a
            let s = CABasicAnimation(keyPath: "transform.scale")
            s.fromValue = 1
            s.toValue = 1.35
            let g = CAAnimationGroup()
            g.animations = [o, s]
            g.duration = star.period / 2
            g.autoreverses = true
            g.repeatCount = .infinity
            g.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // Started in the past, each by its own amount, so no two stars keep step.
            g.beginTime = dot.convertTime(CACurrentMediaTime(), from: nil) - star.phase * star.period
            g.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12)
            dot.add(g, forKey: "twinkle")
        }
    }

    /// A light slides along the edge, from the day behind into the night ahead, in four and a half seconds.
    private func slideGlint() {
        guard running else { return }
        let L = layout_
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = (L.minAngle - 3) * .pi / 180
        turn.toValue = (L.maxAngle + 3) * .pi / 180
        turn.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let show = CAKeyframeAnimation(keyPath: "opacity")
        show.values = [0, 0.38, 0.71, 0.92, 1, 0.92, 0.71, 0.38, 0]
        let g = CAAnimationGroup()
        g.animations = [turn, show]
        g.duration = 4.5
        g.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        glintArm.add(g, forKey: "slide")
    }

    // MARK: Finished tasks

    /// A finish that is news (it happened with the panel open, or just before it opened) gets a meteor; an older
    /// one already has its star in the sky.
    private func answer() {
        let first = answered == nil
        var seen = answered ?? []
        var news: [FallenStars.Entry] = []
        for (id, since) in done.sorted(by: { $0.value < $1.value }) {
            let key = "\(id)|\(Int(since.timeIntervalSince1970))"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            guard !FallenStars.has(key) else { continue }
            let entry = FallenStars.add(key)
            let isNews = !first || Date().timeIntervalSince(since) < SessionLight.fresh || Self.pose != nil
            if isNews && running && news.count < 3 { news.append(entry) } else { land(entry, after: nil) }
        }
        answered = seen
        for (i, entry) in news.enumerated() { fall(entry, after: 0.25 + 0.45 * Double(i)) }
    }

    /// The stars already in the sky when the layers are laid out.
    private func placeFallen() {
        fallen.sublayers?.forEach { $0.removeFromSuperlayer() }
        fallenShown = []
        for e in FallenStars.all { land(e, after: nil) }
    }

    /// A star where a meteor ended; with `after` it lights with a flare that many seconds from now.
    private func land(_ entry: FallenStars.Entry, after delay: Double?) {
        guard !fallenShown.contains(entry.key) else { return }
        fallenShown.insert(entry.key)
        let k = k
        let p = FallenStars.landing(entry.slot)
        let at = CGPoint(x: p.x * k, y: p.y * k)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let star = Self.dot(radius: 1.5 * k, room: 1.9, scale: pixels)
        star.position = at
        star.opacity = 0.95
        fallen.addSublayer(star)
        if let delay {
            let begin = fallen.convertTime(CACurrentMediaTime(), from: nil) + delay
            let o = CABasicAnimation(keyPath: "opacity")
            o.fromValue = 0
            o.toValue = 0.95
            let s = CAKeyframeAnimation(keyPath: "transform.scale")
            s.values = [1, 1.8, 1]
            let g = CAAnimationGroup()
            g.animations = [o, s]
            g.duration = 0.6
            g.beginTime = begin
            g.fillMode = .backwards
            star.add(g, forKey: "light")

            // The flare: a soft halo and a cross of light, there for a moment.
            let flare = CALayer()
            flare.position = at
            flare.opacity = 0
            let halo = CAGradientLayer()
            halo.type = .radial
            halo.colors = [NSColor.white.withAlphaComponent(0.5).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
            halo.startPoint = CGPoint(x: 0.5, y: 0.5)
            halo.endPoint = CGPoint(x: 1, y: 1)
            halo.bounds = CGRect(x: 0, y: 0, width: 18 * k, height: 18 * k)
            flare.addSublayer(halo)
            for across in [true, false] {
                let ray = CALayer()
                ray.backgroundColor = NSColor.white.withAlphaComponent(0.8).cgColor
                ray.bounds = CGRect(x: 0, y: 0, width: across ? 20 * k : 0.8 * k, height: across ? 0.8 * k : 20 * k)
                flare.addSublayer(ray)
            }
            fallen.addSublayer(flare)
            let fo = CAKeyframeAnimation(keyPath: "opacity")
            fo.values = [0, 1, 0]
            let fs = CAKeyframeAnimation(keyPath: "transform.scale")
            fs.values = [0.2, 1, 0.2]
            let fg = CAAnimationGroup()
            fg.animations = [fo, fs]
            fg.duration = 0.6
            fg.beginTime = begin
            flare.add(fg, forKey: "flare")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 1) { flare.removeFromSuperlayer() }
        }
        CATransaction.commit()
    }

    /// A meteor falls to where the star will be, and the star lights as it arrives.
    private func fall(_ entry: FallenStars.Entry, after delay: Double) {
        let k = k
        let p = FallenStars.landing(entry.slot)
        let to = CGPoint(x: p.x * k, y: p.y * k)
        let from = CGPoint(x: (p.x + 120) * k, y: max(4, p.y - 52) * k)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let head = CALayer()
        head.position = to
        head.opacity = 0
        // Its own x axis points the way it falls, so the tail trails behind.
        head.setAffineTransform(CGAffineTransform(rotationAngle: atan2(to.y - from.y, to.x - from.x)))
        let tail = CAGradientLayer()
        tail.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.95).cgColor]
        tail.startPoint = CGPoint(x: 0, y: 0.5)
        tail.endPoint = CGPoint(x: 1, y: 0.5)
        tail.bounds = CGRect(x: 0, y: 0, width: 84 * k, height: 1.7 * k)
        tail.cornerRadius = 0.85 * k
        tail.anchorPoint = CGPoint(x: 1, y: 0.5)
        head.addSublayer(tail)
        let halo = CAGradientLayer()
        halo.type = .radial
        halo.colors = [NSColor.white.withAlphaComponent(0.55).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        halo.startPoint = CGPoint(x: 0.5, y: 0.5)
        halo.endPoint = CGPoint(x: 1, y: 1)
        halo.bounds = CGRect(x: 0, y: 0, width: 16 * k, height: 16 * k)
        head.addSublayer(halo)
        let spark = Self.dot(radius: 1.8 * k, room: 1, scale: pixels)
        head.addSublayer(spark)
        fallen.addSublayer(head)

        if let m = Self.pose?.meteor {
            let eased = 1 - (1 - m) * (1 - m)
            head.position = CGPoint(x: from.x + (to.x - from.x) * eased, y: from.y + (to.y - from.y) * eased)
            head.opacity = m > 0 && m < 1 ? 1 : 0
            tail.setAffineTransform(CGAffineTransform(scaleX: max(0.02, sin(.pi * m)), y: 1))
            CATransaction.commit()
            land(entry, after: nil)
            return
        }
        let begin = fallen.convertTime(CACurrentMediaTime(), from: nil) + delay
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: from)
        move.toValue = NSValue(point: to)
        move.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 1, 0.89, 1)
        let show = CABasicAnimation(keyPath: "opacity")
        show.fromValue = 1
        show.toValue = 1
        let g = CAAnimationGroup()
        g.animations = [move, show]
        g.duration = 0.9
        g.beginTime = begin
        head.add(g, forKey: "fall")
        // The tail grows and is drawn back in as the meteor slows.
        let stretch = CAKeyframeAnimation(keyPath: "transform.scale.x")
        stretch.values = [0.02, 0.38, 0.71, 0.92, 1, 0.92, 0.71, 0.38, 0.02]
        stretch.duration = 0.9
        stretch.beginTime = begin
        tail.add(stretch, forKey: "stretch")
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 1.1) { head.removeFromSuperlayer() }
        land(entry, after: delay + 0.75)
    }
}
