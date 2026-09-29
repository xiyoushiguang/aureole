import SwiftUI

/// The black notch body: straight top edge with concave "ears", rounded bottom corners.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var ear: CGFloat = 8

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, ear) }
        set { bottomRadius = newValue.first; ear = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let r = min(bottomRadius, (h - ear) / 2, (w - 2 * ear) / 2)
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addQuadCurve(to: CGPoint(x: ear, y: ear), control: CGPoint(x: 0, y: ear))
        p.addLine(to: CGPoint(x: ear, y: h - r))
        p.addArc(tangent1End: CGPoint(x: ear, y: h), tangent2End: CGPoint(x: ear + r, y: h), radius: r)
        p.addLine(to: CGPoint(x: w - ear - r, y: h))
        p.addArc(tangent1End: CGPoint(x: w - ear, y: h), tangent2End: CGPoint(x: w - ear, y: h - r), radius: r)
        p.addLine(to: CGPoint(x: w - ear, y: ear))
        p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w, y: ear))
        p.closeSubpath()
        return p
    }
}
