// Builds an .iconset from two 1024px renders (main + small-size variant):
// clips each to the macOS icon tile (824pt rounded rect, r=186 on the 1024 grid) so the
// background is transparent, then resamples to every slot iconutil expects.
// Usage: swift make-iconset.swift <main-1024.png> <small-1024.png> <out.iconset>
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 4 else { fputs("usage: make-iconset.swift main.png small.png out.iconset\n", stderr); exit(2) }
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func load(_ p: String) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fputs("cannot read \(p)\n", stderr); exit(1) }
    return img
}

/// Draws `source` (a 1024-grid render) into a transparent `px`×`px` bitmap, clipped to the tile.
func slot(_ source: CGImage, px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(px) / 1024
    // CoreGraphics has a bottom-left origin; the tile is symmetric so the same rect works.
    let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 186 * s, cornerHeight: 186 * s, transform: nil))
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(source, in: CGRect(x: 0, y: 0, width: CGFloat(px), height: CGFloat(px)))
    return ctx.makeImage()!
}

func write(_ img: CGImage, to path: String) {
    let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, img, nil)
    guard CGImageDestinationFinalize(dst) else { fputs("cannot write \(path)\n", stderr); exit(1) }
}

let main = load(args[1]), small = load(args[2])
let outDir = args[3]
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// (file name, pixel size, use small variant)
let slots: [(String, Int, Bool)] = [
    ("icon_16x16", 16, true), ("icon_16x16@2x", 32, true),
    ("icon_32x32", 32, true), ("icon_32x32@2x", 64, false),
    ("icon_128x128", 128, false), ("icon_128x128@2x", 256, false),
    ("icon_256x256", 256, false), ("icon_256x256@2x", 512, false),
    ("icon_512x512", 512, false), ("icon_512x512@2x", 1024, false),
]
for (name, px, useSmall) in slots {
    write(slot(useSmall ? small : main, px: px), to: "\(outDir)/\(name).png")
}
print("iconset written to \(outDir)")
