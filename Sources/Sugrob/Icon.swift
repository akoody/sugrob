import AppKit

/// Draws the app icon with the same flat art as the app.
enum IconMaker {
    private static func render(_ px: Int) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let s = CGFloat(px)
        c.translateBy(x: 0, y: s)
        c.scaleBy(x: 1, y: -1)
        let inset = s * 0.098
        let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let unit = rect.width
        c.addPath(CGPath(roundedRect: rect, cornerWidth: unit * 0.225, cornerHeight: unit * 0.225, transform: nil))
        c.clip()
        c.setFillColor(CGColor(srgbRed: 0.07, green: 0.1, blue: 0.2, alpha: 1))
        c.fill(rect)

        let w = unit * 0.52, h = w * 1.4
        c.saveGState()
        c.translateBy(x: rect.midX - w / 2, y: rect.minY + unit * 0.13)
        Painter.tree(c, w, h)
        c.restoreGState()

        c.setFillColor(CGColor(srgbRed: 0.92, green: 0.95, blue: 1, alpha: 1))
        c.move(to: CGPoint(x: rect.minX, y: rect.minY + unit * 0.8))
        c.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + unit * 0.78),
                   control1: CGPoint(x: rect.minX + unit * 0.34, y: rect.minY + unit * 0.72),
                   control2: CGPoint(x: rect.minX + unit * 0.66, y: rect.minY + unit * 0.86))
        c.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        c.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        c.closePath()
        c.fillPath()

        let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
        return rep.representation(using: .png, properties: [:])!
    }

    static func write(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            try? render(size).write(to: URL(fileURLWithPath: "\(dir)/icon_\(size)x\(size).png"))
            try? render(size * 2).write(to: URL(fileURLWithPath: "\(dir)/icon_\(size)x\(size)@2x.png"))
        }
    }
}
