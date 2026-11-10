import AppKit
import CoreGraphics
import Metal

/// Every sprite is painted at launch, so the app ships with no image assets.
enum Sprite: Int, CaseIterable {
    case dot, glow, bulb, wire, body, eye, carrot, arm, scarf, hat, button, splat, tree, treeSnow

    var pixels: (Int, Int) {
        switch self {
        case .dot: return (48, 48)
        case .glow: return (96, 96)
        case .bulb: return (32, 32)
        case .wire: return (8, 8)
        case .body: return (256, 256)
        case .eye: return (32, 32)
        case .carrot: return (128, 48)
        case .arm: return (192, 64)
        case .scarf: return (192, 48)
        case .hat: return (192, 192)
        case .button: return (24, 24)
        case .splat: return (256, 256)
        case .tree, .treeSnow: return (320, 448)
        }
    }
}

private func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

private func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
               colors: stops.map { $0.0 } as CFArray, locations: stops.map { $0.1 })!
}

enum Painter {
    static func radial(_ c: CGContext, _ w: CGFloat, _ h: CGFloat, _ stops: [(CGColor, CGFloat)]) {
        c.drawRadialGradient(gradient(stops), startCenter: CGPoint(x: w / 2, y: h / 2), startRadius: 0,
                             endCenter: CGPoint(x: w / 2, y: h / 2), endRadius: min(w, h) / 2, options: [])
    }

    static func sphere(_ c: CGContext, _ s: CGFloat) {
        let inset = s * 0.02
        c.saveGState()
        c.addEllipse(in: CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset))
        c.clip()
        c.drawRadialGradient(gradient([(color(1, 1, 1), 0), (color(1, 1, 1), 0.55), (color(0.88, 0.92, 0.98), 1)]),
                             startCenter: CGPoint(x: s * 0.42, y: s * 0.36), startRadius: 0,
                             endCenter: CGPoint(x: s * 0.48, y: s * 0.48), endRadius: s * 0.56, options: [])
        c.restoreGState()
    }

    static func splat(_ c: CGContext, _ s: CGFloat) {
        var r = SeededRandom(11)
        let m = Double(s) / 2, n = 18
        var pts: [CGPoint] = []
        for i in 0..<n {
            let a = Double(i) / Double(n) * .pi * 2
            let d = r.range(0.2, 0.33) * Double(s)
            pts.append(CGPoint(x: m + cos(a) * d, y: m + sin(a) * d))
        }
        c.setFillColor(color(1, 1, 1))
        c.move(to: CGPoint(x: (pts[0].x + pts[n - 1].x) / 2, y: (pts[0].y + pts[n - 1].y) / 2))
        for i in 0..<n {
            let a = pts[i], b = pts[(i + 1) % n]
            c.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: a)
        }
        c.fillPath()
    }

    static func carrot(_ c: CGContext, _ w: CGFloat, _ h: CGFloat) {
        c.setFillColor(color(0.95, 0.5, 0.16))
        c.move(to: CGPoint(x: 3, y: h * 0.14))
        c.addLine(to: CGPoint(x: w - 3, y: h * 0.5))
        c.addLine(to: CGPoint(x: 3, y: h * 0.86))
        c.closePath()
        c.fillPath()
    }

    static func arm(_ c: CGContext, _ w: CGFloat, _ h: CGFloat) {
        c.setLineCap(.round)
        c.setStrokeColor(color(0.22, 0.17, 0.14))
        c.setLineWidth(h * 0.075)
        let m = h / 2
        c.move(to: CGPoint(x: 4, y: m)); c.addLine(to: CGPoint(x: w - 6, y: m)); c.strokePath()
        c.move(to: CGPoint(x: w * 0.74, y: m)); c.addLine(to: CGPoint(x: w * 0.9, y: m - h * 0.34)); c.strokePath()
    }

    static func hat(_ c: CGContext, _ s: CGFloat) {
        c.setFillColor(color(0.76, 0.14, 0.17))
        c.move(to: CGPoint(x: s * 0.16, y: s * 0.8))
        c.addCurve(to: CGPoint(x: s * 0.84, y: s * 0.8), control1: CGPoint(x: s * 0.16, y: s * 0.14), control2: CGPoint(x: s * 0.84, y: s * 0.14))
        c.closePath()
        c.fillPath()
        c.setFillColor(color(1, 1, 1))
        c.addPath(CGPath(roundedRect: CGRect(x: s * 0.12, y: s * 0.7, width: s * 0.76, height: s * 0.15), cornerWidth: s * 0.07, cornerHeight: s * 0.07, transform: nil))
        c.fillPath()
        c.fillEllipse(in: CGRect(x: s * 0.41, y: s * 0.08, width: s * 0.18, height: s * 0.18))
    }

    static let treeTiers: [(top: CGFloat, bottom: CGFloat, half: CGFloat)] = [
        (0.34, 0.9, 0.48), (0.18, 0.66, 0.37), (0.05, 0.42, 0.26),
    ]

    /// A point on the gently concave side of a tier. `side` is 1 for the right edge and -1 for the left.
    private static func sidePoint(_ tier: (top: CGFloat, bottom: CGFloat, half: CGFloat), _ w: CGFloat, _ h: CGFloat, side: CGFloat, t: CGFloat) -> CGPoint {
        let mid = w / 2, top = h * tier.top, bottom = h * tier.bottom, half = w * tier.half
        let cx = mid + side * half * 0.36, cy = top + (bottom - top) * 0.64
        let u = 1 - t
        return CGPoint(x: u * u * mid + 2 * u * t * cx + t * t * (mid + side * half), y: u * u * top + 2 * u * t * cy + t * t * bottom)
    }

    /// One bough layer: concave sides and a scalloped hem.
    private static func tierPath(_ tier: (top: CGFloat, bottom: CGFloat, half: CGFloat), _ w: CGFloat, _ h: CGFloat, drop: CGFloat = 0) -> CGPath {
        let mid = w / 2, top = h * tier.top + drop, bottom = h * tier.bottom + drop, half = w * tier.half
        let path = CGMutablePath()
        path.move(to: CGPoint(x: mid, y: top))
        path.addQuadCurve(to: CGPoint(x: mid + half, y: bottom), control: CGPoint(x: mid + half * 0.36, y: top + (bottom - top) * 0.64))
        let scallops = 5
        for i in 0..<scallops {
            let x0 = mid + half - 2 * half * CGFloat(i) / CGFloat(scallops)
            let x1 = mid + half - 2 * half * CGFloat(i + 1) / CGFloat(scallops)
            path.addQuadCurve(to: CGPoint(x: x1, y: bottom), control: CGPoint(x: (x0 + x1) / 2, y: bottom + h * 0.032))
        }
        path.addQuadCurve(to: CGPoint(x: mid, y: top), control: CGPoint(x: mid - half * 0.36, y: top + (bottom - top) * 0.64))
        path.closeSubpath()
        return path
    }

    /// A soft layered fir with a few baubles. Each layer casts a shadow on the one below.
    static func tree(_ c: CGContext, _ w: CGFloat, _ h: CGFloat) {
        let mid = w / 2
        c.setFillColor(color(0.3, 0.2, 0.14))
        c.fill(CGRect(x: mid - w * 0.045, y: h * 0.88, width: w * 0.09, height: h * 0.11))
        for tier in treeTiers {
            let path = tierPath(tier, w, h)
            c.saveGState()
            c.setShadow(offset: CGSize(width: 0, height: -h * 0.014), blur: h * 0.03, color: color(0, 0.05, 0.03, 0.55))
            c.setFillColor(color(0.11, 0.32, 0.24))
            c.addPath(path); c.fillPath()
            c.restoreGState()
            c.saveGState()
            c.addPath(path); c.clip()
            c.drawLinearGradient(gradient([(color(0.24, 0.55, 0.39), 0), (color(0.13, 0.39, 0.28), 0.52), (color(0.07, 0.25, 0.19), 1)]),
                                 start: CGPoint(x: mid - w * tier.half, y: 0), end: CGPoint(x: mid + w * tier.half, y: 0), options: [])
            // Deeper shade under the hem gives each layer some body.
            c.drawLinearGradient(gradient([(color(0, 0.06, 0.04, 0), 0), (color(0, 0.06, 0.04, 0.28), 1)]),
                                 start: CGPoint(x: 0, y: h * (tier.bottom - 0.1)), end: CGPoint(x: 0, y: h * (tier.bottom + 0.03)), options: [])
            c.restoreGState()
        }

        let baubles: [(CGFloat, CGFloat, Bool)] = [
            (-0.22, 0.7, true), (0.12, 0.69, false), (0.3, 0.855, true), (-0.35, 0.865, false),
            (-0.13, 0.47, false), (0.16, 0.45, true), (0.0, 0.25, true),
        ]
        let r = w * 0.03
        for (fx, fy, red) in baubles {
            let x = mid + fx * w, y = fy * h
            c.setFillColor(red ? color(0.82, 0.17, 0.2) : color(0.95, 0.74, 0.3))
            c.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            c.setFillColor(color(1, 1, 1, 0.55))
            c.fillEllipse(in: CGRect(x: x - r * 0.55, y: y - r * 0.6, width: r * 0.6, height: r * 0.6))
        }

        let sr = w * 0.078, cy = h * 0.058
        c.setFillColor(color(1, 0.83, 0.4))
        for i in 0..<10 {
            let a = CGFloat(i) * .pi / 5 - .pi / 2
            let d = i % 2 == 0 ? sr : sr * 0.46
            let p = CGPoint(x: mid + cos(a) * d, y: cy + sin(a) * d)
            if i == 0 { c.move(to: p) } else { c.addLine(to: p) }
        }
        c.closePath()
        c.fillPath()
    }

    /// Snow lying along the sloping edges of each layer, in soft lumps. Drawn over the tree and removable layer by layer.
    static func treeSnow(_ c: CGContext, _ w: CGFloat, _ h: CGFloat) {
        let mid = w / 2
        for (i, tier) in treeTiers.enumerated() {
            let shape = tierPath(tier, w, h)
            c.saveGState()
            c.setBlendMode(.clear)
            c.addPath(shape); c.fillPath()
            c.restoreGState()

            c.saveGState()
            c.addPath(shape); c.clip()
            c.setFillColor(color(1, 1, 1))
            c.fill(CGRect(x: 0, y: 0, width: mid, height: h))
            c.setFillColor(color(0.87, 0.91, 0.98))
            c.fill(CGRect(x: mid, y: 0, width: mid, height: h))
            c.setBlendMode(.clear)
            let drop = h * (0.058 - CGFloat(i) * 0.008)
            c.addPath(tierPath(tier, w, h, drop: drop)); c.fillPath()
            c.setBlendMode(.normal)
            var r = SeededRandom(UInt64(31 + i))
            for side in [CGFloat(1), -1] {
                c.setFillColor(side > 0 ? color(0.87, 0.91, 0.98) : color(1, 1, 1))
                var t: CGFloat = 0.1
                while t < 1.01 {
                    let p = sidePoint(tier, w, h, side: side, t: t)
                    let radius = h * CGFloat(r.range(0.013, 0.024)) * (0.7 + 0.5 * t)
                    c.fillEllipse(in: CGRect(x: p.x - radius, y: p.y + drop * 0.75 - radius, width: radius * 2, height: radius * 2))
                    t += CGFloat(r.range(0.06, 0.1))
                }
            }
            c.restoreGState()
        }
    }

    static func paint(_ sprite: Sprite, _ c: CGContext, _ w: CGFloat, _ h: CGFloat) {
        switch sprite {
        case .dot: radial(c, w, h, [(color(1, 1, 1, 1), 0), (color(1, 1, 1, 0.9), 0.5), (color(1, 1, 1, 0), 1)])
        case .glow: radial(c, w, h, [(color(1, 1, 1, 1), 0), (color(1, 1, 1, 0.3), 0.3), (color(1, 1, 1, 0), 1)])
        case .bulb:
            c.setFillColor(color(1, 1, 1)); c.fillEllipse(in: CGRect(x: 2, y: 2, width: w - 4, height: h - 4))
        case .wire:
            c.setFillColor(color(1, 1, 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        case .body: sphere(c, w)
        case .eye, .button:
            c.setFillColor(color(0.1, 0.1, 0.13)); c.fillEllipse(in: CGRect(x: 2, y: 2, width: w - 4, height: h - 4))
        case .carrot: carrot(c, w, h)
        case .arm: arm(c, w, h)
        case .scarf:
            c.setFillColor(color(1, 1, 1))
            c.addPath(CGPath(roundedRect: CGRect(x: 3, y: 6, width: w - 6, height: h - 12), cornerWidth: h * 0.3, cornerHeight: h * 0.3, transform: nil))
            c.fillPath()
        case .hat: hat(c, w)
        case .splat: splat(c, w)
        case .tree: tree(c, w, h)
        case .treeSnow: treeSnow(c, w, h)
        }
    }
}

final class Atlas {
    private(set) var uv: [SIMD4<Float>]
    let texture: MTLTexture

    init(device: MTLDevice, queue: MTLCommandQueue) {
        let size = 1024
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(size))
        ctx.scaleBy(x: 1, y: -1)

        uv = Array(repeating: .zero, count: Sprite.allCases.count)
        let pad = 6
        var x = pad, y = pad, row = 0
        for sprite in Sprite.allCases.sorted(by: { $0.pixels.1 > $1.pixels.1 }) {
            let (w, h) = sprite.pixels
            if x + w + pad > size { x = pad; y += row + pad; row = 0 }
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(x), y: CGFloat(y))
            ctx.clip(to: CGRect(x: 0, y: 0, width: w, height: h))
            Painter.paint(sprite, ctx, CGFloat(w), CGFloat(h))
            ctx.restoreGState()
            let s = Float(size)
            uv[sprite.rawValue] = SIMD4(Float(x) / s, Float(y) / s, Float(x + w) / s, Float(y + h) / s)
            x += w + pad
            row = max(row, h)
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: true)
        desc.usage = .shaderRead
        texture = device.makeTexture(descriptor: desc)!
        texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: ctx.data!, bytesPerRow: size * 4)
        let cb = queue.makeCommandBuffer()!
        let blit = cb.makeBlitCommandEncoder()!
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        cb.commit()
    }
}
