// Renders the three app icon candidates and a comparison sheet.
// Usage: swift scripts/icon/render-icons.swift [output-dir]   (default: design/icon-candidates)
// Candidates only: nothing here touches Resources/ or the app bundle.
import Foundation
import CoreGraphics
import CoreImage
import CoreText
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "design/icon-candidates")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let ci = CIContext(options: [.workingColorSpace: sRGB, .outputColorSpace: sRGB])

struct RGB {
    var r, g, b: CGFloat
    func cg(_ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: sRGB, components: [r, g, b, a])! }
    func mix(_ o: RGB, _ t: CGFloat) -> RGB { RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t) }
}

// Palette mirrors Sources/Aureole/UI/Theme.swift.
let claude = RGB(r: 0.87, g: 0.49, b: 0.36)
let codex = RGB(r: 0.42, g: 0.80, b: 0.72)
let amber = RGB(r: 1.00, g: 0.73, b: 0.32)
let black = RGB(r: 0, g: 0, b: 0)
let white = RGB(r: 1, g: 1, b: 1)

// MARK: - Canvas helpers (all drawing uses a top-left origin)

let N = 1024
let S = CGFloat(N)
let full = CGRect(x: 0, y: 0, width: S, height: S)
/// macOS icon grid: an 824pt tile centred on the 1024pt canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let cx = S / 2

func bitmap(_ w: Int, _ h: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    return ctx
}

func render(_ w: Int = N, _ h: Int = N, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = bitmap(w, h)
    draw(ctx)
    return ctx.makeImage()!
}

/// Draws an image upright in a top-left-origin context.
func drawImage(_ ctx: CGContext, _ image: CGImage, in rect: CGRect, alpha: CGFloat = 1, blend: CGBlendMode = .normal,
               interpolation: CGInterpolationQuality = .high) {
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.setBlendMode(blend)
    ctx.interpolationQuality = interpolation
    ctx.translateBy(x: rect.minX, y: rect.maxY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
    ctx.restoreGState()
}

func blurred(_ image: CGImage, _ radius: CGFloat) -> CGImage {
    let input = CIImage(cgImage: image)
    let out = input.clampedToExtent().applyingGaussianBlur(sigma: Double(radius)).cropped(to: input.extent)
    return ci.createCGImage(out, from: input.extent)!
}

func linear(_ ctx: CGContext, _ stops: [(CGFloat, CGColor)], from a: CGPoint, to b: CGPoint) {
    let g = CGGradient(colorsSpace: sRGB, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
    ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func radial(_ ctx: CGContext, _ stops: [(CGFloat, CGColor)], center: CGPoint, radius: CGFloat) {
    let g = CGGradient(colorsSpace: sRGB, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
                           options: [.drawsAfterEndLocation])
}

/// Superellipse approximation of the continuous-corner icon tile.
func squircle(_ rect: CGRect, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 1440
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let pt = CGPoint(x: rect.midX + a * copysign(pow(abs(c), 2 / n), c),
                         y: rect.midY + b * copysign(pow(abs(s), 2 / n), s))
        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    p.closeSubpath()
    return p
}

/// The notch outline hanging from the top edge, optionally grown outward by `grow`.
/// `closed` gives the filled silhouette; otherwise an open U for stroking.
func notch(width: CGFloat, bottom: CGFloat, radius: CGFloat, grow d: CGFloat = 0, closed: Bool = true) -> CGPath {
    let x0 = cx - width / 2 - d, x1 = cx + width / 2 + d
    let yb = bottom + d, r = radius + d
    let p = CGMutablePath()
    p.move(to: CGPoint(x: x0, y: -80))
    p.addLine(to: CGPoint(x: x0, y: yb - r))
    p.addArc(tangent1End: CGPoint(x: x0, y: yb), tangent2End: CGPoint(x: x0 + r, y: yb), radius: r)
    p.addLine(to: CGPoint(x: x1 - r, y: yb))
    p.addArc(tangent1End: CGPoint(x: x1, y: yb), tangent2End: CGPoint(x: x1, y: yb - r), radius: r)
    p.addLine(to: CGPoint(x: x1, y: -80))
    if closed { p.closeSubpath() }
    return p
}

func strokeGradient(_ ctx: CGContext, _ path: CGPath, width: CGFloat, cap: CGLineCap = .butt,
                    _ stops: [(CGFloat, CGColor)], from a: CGPoint, to b: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setLineWidth(width)
    ctx.setLineCap(cap)
    ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    linear(ctx, stops, from: a, to: b)
    ctx.restoreGState()
}

/// Adds the soft bloom of a light layer, then the crisp layer itself.
func glow(_ ctx: CGContext, _ light: CGImage, wide: CGFloat, tight: CGFloat, strength: CGFloat = 1, crisp: Bool = true) {
    drawImage(ctx, blurred(light, wide), in: full, alpha: 0.85 * strength, blend: .plusLighter)
    drawImage(ctx, blurred(light, tight), in: full, alpha: 0.70 * strength, blend: .plusLighter)
    if crisp { drawImage(ctx, light, in: full) }
}

/// Puts tile content on the canvas: drop shadow, squircle clip, faint rim so the tile holds on dark docks.
func tileIcon(_ content: CGImage) -> CGImage {
    render { ctx in
        let shape = squircle(tile)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: black.cg(0.42))
        ctx.addPath(shape)
        ctx.setFillColor(black.cg())
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        drawImage(ctx, content, in: full)
        // Rim: brighter along the top, fading down the sides.
        ctx.addPath(shape)
        ctx.setLineWidth(6)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        linear(ctx, [(0, white.cg(0.20)), (0.5, white.cg(0.07)), (1, white.cg(0.04))],
               from: CGPoint(x: 0, y: tile.minY), to: CGPoint(x: 0, y: tile.maxY))
        ctx.restoreGState()
    }
}

// MARK: - A · Notch with two light bars (the collapsed UI, literally)

func candidateA() -> CGImage {
    let nW: CGFloat = 600, nB: CGFloat = 336, nR: CGFloat = 78
    let barY = nB - 62, barH: CGFloat = 66, gap: CGFloat = 54, len: CGFloat = 176
    let lanes: [(RGB, CGFloat, CGFloat)] = [(claude, cx - gap - len, cx - gap), (codex, cx + gap, cx + gap + len)]

    let bars = render { ctx in
        ctx.setLineCap(.round)
        ctx.setLineWidth(barH)
        for (color, x0, x1) in lanes {
            ctx.setStrokeColor(color.cg())
            ctx.move(to: CGPoint(x: x0, y: barY))
            ctx.addLine(to: CGPoint(x: x1, y: barY))
            ctx.strokePath()
        }
    }
    // Light falling out from under the notch lip.
    let spill = render { ctx in
        // Two tall soft pools that overlap in the middle, so the colours blend instead of meeting at a seam.
        let stretch: CGFloat = 1.55, reach: CGFloat = 330
        ctx.setBlendMode(.plusLighter)
        for (color, x0, x1) in lanes {
            let c = CGPoint(x: (x0 + x1) / 2, y: nB - 20)
            ctx.saveGState()
            ctx.translateBy(x: c.x, y: c.y)
            ctx.scaleBy(x: 1, y: stretch)
            radial(ctx, [(0, color.cg(0.78)), (0.35, color.cg(0.40)), (0.7, color.cg(0.12)), (1, color.cg(0))],
                   center: .zero, radius: reach)
            ctx.restoreGState()
        }
    }
    return tileIcon(render { ctx in
        linear(ctx, [(0, RGB(r: 0.20, g: 0.21, b: 0.28).cg()), (1, RGB(r: 0.05, g: 0.055, b: 0.08).cg())],
               from: CGPoint(x: 0, y: tile.minY), to: CGPoint(x: 0, y: tile.maxY))
        drawImage(ctx, blurred(spill, 30), in: full, alpha: 0.80, blend: .plusLighter)
        ctx.addPath(notch(width: nW, bottom: nB, radius: nR))
        ctx.setFillColor(black.cg())
        ctx.fillPath()
        glow(ctx, bars, wide: 64, tight: 20)
        // Tube highlight along the upper half of each bar.
        ctx.setLineCap(.round)
        ctx.setLineWidth(barH * 0.22)
        ctx.setStrokeColor(white.cg(0.38))
        for (_, x0, x1) in lanes {
            ctx.move(to: CGPoint(x: x0 + 6, y: barY - barH * 0.18))
            ctx.addLine(to: CGPoint(x: x1 - 6, y: barY - barH * 0.18))
            ctx.strokePath()
        }
    })
}

// MARK: - B · Halo ring behind the notch (quota as a gauge)

func candidateB() -> CGImage {
    let c = CGPoint(x: cx, y: 566), R: CGFloat = 250, W: CGFloat = 92
    // The lit arc runs from `start` to `used`; the rest of the ring is spent and dim, passing behind the notch.
    let start: CGFloat = 0.095, used: CGFloat = 0.80
    let stops: [(CGFloat, RGB)] = [(0, claude), (0.26, claude), (0.43, amber), (0.62, codex), (1, codex)]
    func color(at t: CGFloat) -> RGB {
        for i in 1..<stops.count where t <= stops[i].0 {
            let (t0, c0) = stops[i - 1], (t1, c1) = stops[i]
            return c0.mix(c1, (t - t0) / (t1 - t0))
        }
        return stops.last!.1
    }
    // t runs from 12 o'clock anticlockwise, so Claude's orange sits on the left and Codex's teal on the right.
    func angle(_ t: CGFloat) -> CGFloat { -.pi / 2 - t * 2 * .pi }
    func point(_ t: CGFloat, _ r: CGFloat) -> CGPoint { CGPoint(x: c.x + r * cos(angle(t)), y: c.y + r * sin(angle(t))) }

    let ring = render { ctx in
        let steps = 480
        for i in 0..<steps {
            let t0 = start + (used - start) * CGFloat(i) / CGFloat(steps)
            let t1 = min(used, start + (used - start) * (CGFloat(i) + 1.6) / CGFloat(steps))   // overlap hides seams
            ctx.setFillColor(color(at: t0).cg())
            ctx.move(to: point(t0, R - W / 2))
            ctx.addLine(to: point(t0, R + W / 2))
            ctx.addLine(to: point(t1, R + W / 2))
            ctx.addLine(to: point(t1, R - W / 2))
            ctx.closePath()
            ctx.fillPath()
        }
        for t in [start, used] {
            let p = point(t, R)
            ctx.setFillColor(color(at: t).cg())
            ctx.fillEllipse(in: CGRect(x: p.x - W / 2, y: p.y - W / 2, width: W, height: W))
        }
    }
    return tileIcon(render { ctx in
        ctx.setFillColor(RGB(r: 0.035, g: 0.037, b: 0.05).cg())
        ctx.fill(full)
        radial(ctx, [(0, RGB(r: 0.17, g: 0.18, b: 0.24).cg()), (1, RGB(r: 0.035, g: 0.037, b: 0.05).cg())],
               center: CGPoint(x: cx, y: 420), radius: 640)
        // Spent part of the ring.
        ctx.setStrokeColor(white.cg(0.13))
        ctx.setLineWidth(W)
        ctx.strokeEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
        glow(ctx, ring, wide: 58, tight: 18)
        // Inner-edge highlight for a little volume.
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
        ctx.setLineWidth(W)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        drawImage(ctx, render { m in
            m.setStrokeColor(white.cg(0.26))
            m.setLineWidth(W * 0.14)
            m.setLineCap(.round)
            m.move(to: point(start + 0.01, R + W * 0.20))
            for i in 1...200 { m.addLine(to: point(start + 0.01 + (used - start - 0.02) * CGFloat(i) / 200, R + W * 0.20)) }
            m.strokePath()
        }, in: full, alpha: 0.9)
        ctx.restoreGState()

        ctx.addPath(notch(width: 400, bottom: 314, radius: 66))
        ctx.setFillColor(black.cg())
        ctx.fillPath()
    })
}

// MARK: - C · Halos rippling out from the notch outline

func candidateC() -> CGImage {
    let nW: CGFloat = 340, nB: CGFloat = 272, nR: CGFloat = 62
    let sweep: [(CGFloat, CGColor)] = [(0, claude.cg()), (0.34, claude.mix(amber, 0.85).cg()), (0.68, codex.cg()), (1, codex.cg())]
    let rings: [(grow: CGFloat, width: CGFloat, alpha: CGFloat)] = [(60, 74, 1.0), (178, 42, 0.60), (286, 26, 0.36), (382, 15, 0.20)]

    func layer(_ picks: ArraySlice<(grow: CGFloat, width: CGFloat, alpha: CGFloat)>) -> CGImage {
        render { ctx in
            for ring in picks {
                ctx.saveGState()
                ctx.setAlpha(ring.alpha)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                strokeGradient(ctx, notch(width: nW, bottom: nB, radius: nR, grow: ring.grow, closed: false),
                               width: ring.width, sweep, from: CGPoint(x: cx - 290, y: 0), to: CGPoint(x: cx + 290, y: 0))
                ctx.endTransparencyLayer()
                ctx.restoreGState()
            }
        }
    }
    return tileIcon(render { ctx in
        linear(ctx, [(0, RGB(r: 0.13, g: 0.135, b: 0.18).cg()), (1, RGB(r: 0.03, g: 0.032, b: 0.045).cg())],
               from: CGPoint(x: 0, y: tile.minY), to: CGPoint(x: 0, y: tile.maxY))
        glow(ctx, layer(rings[1...]), wide: 40, tight: 12, strength: 0.7)
        glow(ctx, layer(rings[..<1]), wide: 60, tight: 18)
        strokeGradient(ctx, notch(width: nW, bottom: nB, radius: nR, grow: rings[0].grow - rings[0].width * 0.20, closed: false),
                       width: rings[0].width * 0.16, [(0, white.cg(0.34)), (1, white.cg(0.34))],
                       from: .zero, to: CGPoint(x: S, y: 0))
        ctx.addPath(notch(width: nW, bottom: nB, radius: nR))
        ctx.setFillColor(black.cg())
        ctx.fillPath()
    })
}

// MARK: - Output

func writePNG(_ image: CGImage, _ name: String) {
    let url = outDir.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
    print("wrote \(url.path) \(image.width)x\(image.height)")
}

func scaled(_ image: CGImage, _ px: Int) -> CGImage {
    render(px, px) { ctx in drawImage(ctx, image, in: CGRect(x: 0, y: 0, width: px, height: px)) }
}

func text(_ ctx: CGContext, _ string: String, at p: CGPoint, size: CGFloat, color: CGColor, bold: Bool = false, centered: Bool = false) {
    let font = CTFontCreateWithName((bold ? "PingFangSC-Semibold" : "PingFangSC-Regular") as CFString, size, nil)
    let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs))
    let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    ctx.saveGState()
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.textPosition = CGPoint(x: centered ? p.x - w / 2 : p.x, y: p.y)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

let candidates: [(file: String, title: String, note: String, image: CGImage)] = [
    ("A-notch-bars.png", "A · 刘海光条", "收起态的样子：两道光条，光从刘海下沿洒出", candidateA()),
    ("B-halo-ring.png", "B · 光环", "额度做成一圈光环，用掉的一段变暗", candidateB()),
    ("C-notch-aura.png", "C · 光晕涟漪", "光贴着刘海轮廓一圈圈向外散开", candidateC()),
]
for c in candidates { writePNG(c.image, c.file) }

// Comparison sheet: large preview, then real-size 128/64/32 and a 4x pixel view of the 32, on dark and light.
let colW = 600, pad = 40, sheetW = pad + candidates.count * colW, sheetH = 1180
let sheet = render(sheetW, sheetH) { ctx in
    ctx.setFillColor(RGB(r: 0.16, g: 0.16, b: 0.18).cg())
    ctx.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))
    for (i, c) in candidates.enumerated() {
        let x = CGFloat(pad + i * colW), w = CGFloat(colW - pad)
        text(ctx, c.title, at: CGPoint(x: x, y: 70), size: 38, color: white.cg(0.95), bold: true)
        text(ctx, c.note, at: CGPoint(x: x, y: 112), size: 21, color: white.cg(0.60))
        drawImage(ctx, c.image, in: CGRect(x: x + (w - 520) / 2, y: 140, width: 520, height: 520))

        let strips: [(y: CGFloat, fill: RGB, ink: RGB, label: String)] = [
            (690, RGB(r: 0.10, g: 0.10, b: 0.12), white, "深色背景"), (930, RGB(r: 0.92, g: 0.92, b: 0.94), black, "浅色背景")]
        for s in strips {
            let box = CGRect(x: x, y: s.y, width: w, height: 220)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: 18, cornerHeight: 18, transform: nil))
            ctx.setFillColor(s.fill.cg())
            ctx.fillPath()
            text(ctx, s.label, at: CGPoint(x: x + 18, y: s.y + 32), size: 18, color: s.ink.cg(0.55))
            var px = x + 22
            let base = s.y + 172
            for size in [128, 64, 32] {
                let small = scaled(c.image, size)
                drawImage(ctx, small, in: CGRect(x: px, y: base - CGFloat(size), width: CGFloat(size), height: CGFloat(size)),
                          interpolation: .none)
                text(ctx, "\(size)", at: CGPoint(x: px + CGFloat(size) / 2, y: base + 28), size: 16, color: s.ink.cg(0.55), centered: true)
                px += CGFloat(size) + 26
            }
            drawImage(ctx, scaled(c.image, 32), in: CGRect(x: px + 10, y: base - 128, width: 128, height: 128), interpolation: .none)
            text(ctx, "32 放大 4 倍", at: CGPoint(x: px + 74, y: base + 28), size: 16, color: s.ink.cg(0.55), centered: true)
        }
    }
}
writePNG(sheet, "compare.png")
