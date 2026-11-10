import AppKit
import Metal
import simd

/// Developer tool: renders a scene over a plain background and prints simulation timing.
enum Snapshot {
    static func run(output: String, realWindows: Bool) {
        guard let screen = NSScreen.main else { return }
        Sound.shared.muted = true
        let world = World(screen: screen, primary: true)
        let renderer = Renderer(world: world)
        let W = CGFloat(world.size.x), H = CGFloat(world.size.y)
        let ox = world.cgFrame.minX, oy = world.cgFrame.minY

        let staged = [CGRect(x: W * 0.3, y: H * 0.18, width: W * 0.42, height: H * 0.56)]
        let windows: [WindowInfo] = realWindows ? WindowTracker().visibleWindows() : staged.enumerated().map { i, r in
            WindowInfo(id: CGWindowID(9000 + i), frame: r.offsetBy(dx: ox, dy: oy))
        }
        _ = world.syncWindows(windows, pollDt: 0.1, existing: { Set(windows.map { $0.id }) })

        let info = FrameInfo(dt: 1.0 / 30, mouse: V2(Float(ox) - 500, Float(oy) - 500), mouseVelocity: .zero, play: false, tool: .snowman)
        for _ in 0..<300 { world.update(info) }

        world.addSnowman(on: world.ground, x: world.size.x * 0.1, R: 34)
        if ProcessInfo.processInfo.environment["SUGROB_FIREWORKS"] != nil { world.startFireworks(seconds: 6) }
        for _ in 0..<60 { world.update(info) }

        let start = CACurrentMediaTime()
        for _ in 0..<600 { world.update(info) }
        let simMs = (CACurrentMediaTime() - start) * 1000 / 600
        if ProcessInfo.processInfo.environment["SUGROB_FIREWORKS"] != nil {
            world.startFireworks(seconds: 6)
            for _ in 0..<45 { world.update(info) }
        }

        let w = Int(world.size.x * world.backing), h = Int(world.size.y * world.backing)
        let tex = renderer.renderOffscreen(width: w, height: h)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&pixels, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)

        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info32 = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info32)!
        ctx.setFillColor(CGColor(srgbRed: 0.08, green: 0.1, blue: 0.16, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let k = CGFloat(world.backing)
        for info in windows.reversed() {
            let r = info.frame.offsetBy(dx: -ox, dy: -oy)
            ctx.setFillColor(CGColor(srgbRed: 0.15, green: 0.16, blue: 0.19, alpha: 1))
            ctx.addPath(CGPath(roundedRect: CGRect(x: r.minX * k, y: CGFloat(h) - r.maxY * k, width: r.width * k, height: r.height * k), cornerWidth: 20, cornerHeight: 20, transform: nil))
            ctx.fillPath()
        }
        let overlay = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: info32)!
        ctx.draw(overlay.makeImage()!, in: CGRect(x: 0, y: 0, width: w, height: h))
        try? NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
        print(String(format: "screen %.0fx%.0f, simulation %.3f ms per frame", world.size.x, world.size.y, simMs))
    }
}
