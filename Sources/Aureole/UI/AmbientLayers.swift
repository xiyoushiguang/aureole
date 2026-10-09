import AppKit
import SwiftUI

// Continuous motion handed to Core Animation. The window server runs these animations, so the app does no
// work per frame; doing the same with SwiftUI's repeating animations re-rendered the panel every frame
// (about a fifth of a CPU core for the breathing glow alone).

/// A layer-backed view whose top-left is the origin, like SwiftUI's.
final class FlippedLayerView: NSView {
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// An image whose opacity rises and falls slowly, forever.
struct BreathingImage: NSViewRepresentable {
    let image: NSImage
    var low: Float = 0.55
    var period: Double = 4.4

    func makeNSView(context: Context) -> FlippedLayerView {
        let v = FlippedLayerView()
        v.layer?.contentsGravity = .resize
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = low
        a.toValue = 1
        a.duration = period / 2
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // A four-second fade needs nowhere near 60 frames a second; every frame is a recomposite of the panel.
        a.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 12, preferred: 10)
        v.layer?.add(a, forKey: "breathe")
        return v
    }

    func updateNSView(_ v: FlippedLayerView, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        v.layer?.contents = image
        CATransaction.commit()
    }
}

/// A dashed polyline whose dashes flow from its first point toward its last.
struct FlowingDashes: NSViewRepresentable {
    /// Points in the view's own coordinates.
    let points: [CGPoint]
    let color: NSColor
    var lineWidth: CGFloat = 2
    var dash: CGFloat = 5

    func makeNSView(context: Context) -> FlippedLayerView {
        let v = FlippedLayerView()
        let shape = CAShapeLayer()
        shape.fillColor = nil
        shape.lineCap = .butt
        v.layer?.addSublayer(shape)
        let a = CABasicAnimation(keyPath: "lineDashPhase")
        a.fromValue = 0
        a.toValue = -2 * dash
        a.duration = 1.25
        a.repeatCount = .infinity
        a.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 15, preferred: 15)
        shape.add(a, forKey: "flow")
        return v
    }

    func updateNSView(_ v: FlippedLayerView, context: Context) {
        guard let shape = v.layer?.sublayers?.first as? CAShapeLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGMutablePath()
        if let first = points.first {
            path.move(to: first)
            for p in points.dropFirst() { path.addLine(to: p) }
        }
        // Only the line's own bounds get redrawn as the dashes move.
        let box = path.boundingBox.insetBy(dx: -lineWidth, dy: -lineWidth)
        shape.frame = box
        var shift = CGAffineTransform(translationX: -box.minX, y: -box.minY)
        shape.path = path.copy(using: &shift)
        shape.strokeColor = color.cgColor
        shape.lineWidth = lineWidth
        shape.lineDashPattern = [NSNumber(value: Double(dash)), NSNumber(value: Double(dash))]
        CATransaction.commit()
    }
}

/// A circle (filled, or a ring when `lineWidth` is set) that pulses in scale and opacity on Core Animation.
/// `autoreverses` pulses forever; otherwise it plays `repeats` times from start to end and rests invisible,
/// replaying whenever `trigger` changes (a ripple).
struct PulsingCircle: NSViewRepresentable {
    var diameter: CGFloat
    var color: NSColor
    var lineWidth: CGFloat? = nil
    var scale: (from: CGFloat, to: CGFloat) = (0.92, 1.15)
    var opacity: (from: Float, to: Float) = (1, 0.35)
    var period: Double = 2.2
    var autoreverses = true
    var repeats: Float = .infinity
    var trigger = 0
    var fps: Float = 20

    final class Coordinator { var trigger = Int.min }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> CenteredShapeView { CenteredShapeView() }

    func updateNSView(_ v: CenteredShapeView, context: Context) {
        let shape = v.shape
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        v.diameter = diameter
        shape.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: diameter, height: diameter), transform: nil)
        if let lineWidth {
            shape.fillColor = nil
            shape.strokeColor = color.cgColor
            shape.lineWidth = lineWidth
        } else {
            shape.fillColor = color.cgColor
            shape.strokeColor = nil
        }
        // At rest a ripple is invisible; a pulse rests at its first frame.
        shape.opacity = autoreverses ? opacity.from : 0
        CATransaction.commit()
        v.needsLayout = true
        guard context.coordinator.trigger != trigger else { return }
        context.coordinator.trigger = trigger
        let s = CABasicAnimation(keyPath: "transform.scale")
        s.fromValue = scale.from
        s.toValue = scale.to
        let o = CABasicAnimation(keyPath: "opacity")
        o.fromValue = opacity.from
        o.toValue = opacity.to
        let g = CAAnimationGroup()
        g.animations = [s, o]
        g.duration = autoreverses ? period / 2 : period
        g.autoreverses = autoreverses
        g.repeatCount = repeats
        g.timingFunction = CAMediaTimingFunction(name: autoreverses ? .easeInEaseOut : .easeOut)
        g.preferredFrameRateRange = CAFrameRateRange(minimum: fps / 2, maximum: fps, preferred: fps)
        shape.removeAnimation(forKey: "pulse")
        shape.add(g, forKey: "pulse")
    }
}

/// Holds one shape layer centred in the view, whatever size SwiftUI gives it.
final class CenteredShapeView: NSView {
    let shape = CAShapeLayer()
    var diameter: CGFloat = 10
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(shape)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        shape.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }
}
