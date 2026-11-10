import AppKit
import MetalKit

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { PlayState.shared.active }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class OverlayView: MTKView {
    weak var coordinator: Coordinator?
    var world: World!
    private var last = V2.zero

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func point(_ e: NSEvent) -> V2 {
        V2(Float(e.locationInWindow.x), Float(bounds.height - e.locationInWindow.y))
    }

    override func resetCursorRects() {
        guard PlayState.shared.active else { return }
        addCursorRect(bounds, cursor: Cursors.current(PlayState.shared.tool))
    }

    override func mouseDown(with e: NSEvent) {
        let p = point(e)
        last = p
        coordinator?.noteInput()
        world.pointerDown(p, tool: PlayState.shared.tool)
    }

    override func mouseDragged(with e: NSEvent) {
        let p = point(e)
        coordinator?.noteInput()
        world.pointerDragged(from: last, to: p, velocity: coordinator?.velocity ?? .zero, tool: PlayState.shared.tool)
        last = p
    }

    override func mouseUp(with e: NSEvent) {
        coordinator?.noteInput()
        world.pointerUp(point(e), velocity: coordinator?.velocity ?? .zero, tool: PlayState.shared.tool)
    }

    override func keyDown(with e: NSEvent) {
        coordinator?.noteInput()
        switch e.keyCode {
        case 53: coordinator?.setPlay(false)        // Esc
        case 18: coordinator?.select(.snowball)     // 1
        case 19: coordinator?.select(.snowman)      // 2
        default: break
        }
    }
}

enum Cursors {
    static func current(_ tool: Tool) -> NSCursor {
        tool == .snowball ? .crosshair : .openHand
    }
}

/// Sits above the Metal view and never takes the mouse.
final class LightsView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One transparent, click-through layer per display.
final class Overlay: NSObject {
    let window: OverlayWindow
    let view: OverlayView
    let world: World
    let renderer: Renderer

    private var link: AnyObject?
    private var fallback: Timer?
    private var lastTarget: CFTimeInterval = 0
    private var onFrame: ((Float) -> Void)?
    private var currentFPS: Float = 0

    private let lightsView: LightsView
    private let garlandLayer = CALayer()
    private let treeLayer = CALayer()
    private var builtGarland = -1
    private var shownGarland: Bool?
    private var shownTree: Bool?
    private var treePosition = CGPoint(x: -1, y: -1)
    private var treeTilt: Float = 100
    private var images: [String: CGImage] = [:]
    private(set) var lightsAnimating = true

    init(screen: NSScreen, primary: Bool, coordinator: Coordinator) {
        world = World(screen: screen, primary: primary)
        world.lightsInMetal = false
        renderer = Renderer(world: world)
        window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let bounds = NSRect(origin: .zero, size: screen.frame.size)
        view = OverlayView(frame: bounds, device: GPU.shared.device)
        view.world = world
        view.coordinator = coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.depthStencilStorageMode = GPU.shared.device.supportsFamily(.apple1) ? .memoryless : .private
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.clearDepth = 1
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.delegate = renderer
        view.autoresizingMask = [.width, .height]
        view.layer?.isOpaque = false
        if let layer = view.layer as? CAMetalLayer {
            layer.isOpaque = false
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            layer.maximumDrawableCount = 2
        }

        lightsView = LightsView(frame: bounds)
        lightsView.wantsLayer = true
        lightsView.autoresizingMask = [.width, .height]
        let container = NSView(frame: bounds)
        container.wantsLayer = true
        container.addSubview(view)
        container.addSubview(lightsView)
        window.contentView = container
        super.init()
        lightsView.layer?.addSublayer(garlandLayer)
        lightsView.layer?.addSublayer(treeLayer)
        buildTreeLights()
        syncLights()
        window.orderFrontRegardless()
    }

    // MARK: Lights

    /// The glow and core of one lamp. The compositor clamps colour to alpha, so the halo is an ordinary
    /// translucent warm disc rather than added light.
    private func lightImage(tint: SIMD3<Float>, halo: CGFloat, core: CGFloat) -> CGImage? {
        let key = "\(tint.x)-\(tint.y)-\(tint.z)-\(halo)-\(core)"
        if let cached = images[key] { return cached }
        let scale = CGFloat(world.backing)
        let px = max(4, Int((halo * scale).rounded(.up)))
        var data = [UInt8](repeating: 0, count: px * px * 4)
        let c = Float(px) / 2, coreR = Float(core * scale) / 2
        let bright = tint + (SIMD3<Float>(repeating: 1) - tint) * 0.3
        for y in 0..<px {
            for x in 0..<px {
                let d = hypot(Float(x) + 0.5 - c, Float(y) + 0.5 - c)
                let t = d / c
                // A tight bright ring around the lamp plus a wide soft bloom.
                let g: Float = 0.75 * pow(max(0, 1 - t), 3.2) + 0.25 * pow(max(0, 1 - t), 1.4)
                let k = coreR > 0.5 ? clampf(coreR - d + 0.5, 0, 1) : 0
                let hot = bright + (SIMD3<Float>(repeating: 1) - bright) * clampf(1 - d / max(coreR, 0.5), 0, 1) * 0.8
                let glow = min(1, 0.62 * g)
                let rgb = hot * k + tint * (glow * (1 - k))
                let a = k + glow * (1 - k)
                let i = (y * px + x) * 4
                data[i] = UInt8(clampf(rgb.x, 0, 1) * 255)
                data[i + 1] = UInt8(clampf(rgb.y, 0, 1) * 255)
                data[i + 2] = UInt8(clampf(rgb.z, 0, 1) * 255)
                data[i + 3] = UInt8(clampf(a, 0, 1) * 255)
            }
        }
        let image = data.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(data: raw.baseAddress, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        images[key] = image
        return image
    }

    /// The compositor animates the opacity. The app does no work for a twinkling lamp.
    private func lamp(at p: CGPoint, tint: SIMD3<Float>, halo: CGFloat, core: CGFloat, dimTo: Float, halfPeriod: Double, phase: Double) -> CALayer {
        let l = CALayer()
        l.bounds = CGRect(x: 0, y: 0, width: halo, height: halo)
        l.position = p
        l.contents = lightImage(tint: tint, halo: halo, core: core)
        l.contentsScale = CGFloat(world.backing)
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1
        a.toValue = dimTo
        a.duration = halfPeriod
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        a.timeOffset = phase.truncatingRemainder(dividingBy: halfPeriod * 2)
        l.add(a, forKey: "twinkle")
        return l
    }

    private func buildGarland() {
        builtGarland = world.garlandVersion
        garlandLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        let h = CGFloat(world.size.y)
        for b in world.bulbs {
            // The phase steps along the strand, so brightness travels down it as a slow wave.
            garlandLayer.addSublayer(lamp(at: CGPoint(x: CGFloat(b.x), y: h - CGFloat(b.y)), tint: b.tint, halo: 40, core: 5.5,
                                          dimTo: 0.55, halfPeriod: 3.5, phase: Double(b.phase) / (2 * .pi) * 7))
        }
    }

    /// Tree lights live in a layer anchored at the foot of the trunk, so the whole set can sway with it.
    private func buildTreeLights() {
        let w = CGFloat(world.treeW), h = CGFloat(world.treeH)
        for (i, l) in World.treeLights.enumerated() {
            treeLayer.addSublayer(lamp(at: CGPoint(x: CGFloat(l.0) * w, y: h - CGFloat(l.1) * h), tint: i % 4 == 1 ? warmRed : warmWhite,
                                       halo: 26, core: 3.8, dimTo: 0.45, halfPeriod: 2.6, phase: Double(i) * 1.4))
        }
        treeLayer.addSublayer(lamp(at: CGPoint(x: 0, y: h - 0.05 * h), tint: warmGold, halo: 60, core: 0, dimTo: 0.65, halfPeriod: 4.5, phase: 0))
    }

    var lightCount: Int { (garlandLayer.sublayers?.count ?? 0) + (treeLayer.sublayers?.count ?? 0) }

    /// Brings the light layers in line with the scene. Cheap enough to call after every frame.
    func syncLights() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if builtGarland != world.garlandVersion { buildGarland() }
        let garland = Settings.shared.garland && !world.hidden
        if shownGarland != garland {
            shownGarland = garland
            garlandLayer.isHidden = !garland
        }
        let tree = world.primary && Settings.shared.tree && !world.hidden
        if shownTree != tree {
            shownTree = tree
            treeLayer.isHidden = !tree
        }
        if tree {
            let p = CGPoint(x: CGFloat(world.treeX), y: CGFloat(world.size.y - world.treeBase))
            if abs(p.x - treePosition.x) > 0.05 || abs(p.y - treePosition.y) > 0.05 {
                treePosition = p
                treeLayer.position = p
            }
            if abs(world.treeTilt - treeTilt) > 0.0005 {
                treeTilt = world.treeTilt
                treeLayer.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(-treeTilt)))
            }
        }
        CATransaction.commit()
    }

    /// Freezes the twinkle while nobody is at the Mac.
    func setLightsAnimating(_ on: Bool) {
        guard on != lightsAnimating, let layer = lightsView.layer else { return }
        lightsAnimating = on
        if on {
            let paused = layer.timeOffset
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
            layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - paused
        } else {
            layer.timeOffset = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0
        }
    }

    // MARK: Frame clock

    /// Frames are tied to this display's refresh, so motion stays even at any refresh rate.
    func startClock(_ handler: @escaping (Float) -> Void) {
        onFrame = handler
        if #available(macOS 14.0, *) {
            let l = view.displayLink(target: self, selector: #selector(step(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        } else {
            setFallback(fps: 30)
        }
    }

    @available(macOS 14.0, *)
    @objc private func step(_ l: CADisplayLink) {
        // Displays do not reliably honor the preferred rate, and the reported duration can be wrong,
        // so frames are gated on real time. Vsync callbacks keep the spacing between them even.
        let interval = 1 / Double(currentFPS > 0 ? currentFPS : 30)
        if lastTarget != 0 && l.targetTimestamp - lastTarget < interval * 0.82 { return }
        let dt = lastTarget == 0 ? interval : l.targetTimestamp - lastTarget
        lastTarget = l.targetTimestamp
        onFrame?(min(Float(dt), 1.0 / 12))
        trace(dt)
    }

    private static let tracing = ProcessInfo.processInfo.environment["SUGROB_TRACE"] != nil
    private var traceSum: Double = 0
    private var traceCount = 0
    private var traceStart = CACurrentMediaTime()

    /// Developer aid: every five seconds prints how many frames were drawn and how long the clock ran.
    private func trace(_ dt: CFTimeInterval) {
        guard Overlay.tracing, dt > 0 else { return }
        traceSum += dt
        traceCount += 1
        let now = CACurrentMediaTime()
        if now - traceStart >= 5 {
            print(String(format: "display %.0f: %d frames in %.1f s, clock ran %.1f s", world.size.x, traceCount, now - traceStart, traceSum))
            fflush(stdout)
            traceSum = 0; traceCount = 0; traceStart = now
        }
    }

    private func setFallback(fps: Float) {
        fallback?.invalidate()
        lastTarget = CACurrentMediaTime()
        let t = Timer(timeInterval: TimeInterval(1 / fps), repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = CACurrentMediaTime()
            let dt = Float(now - self.lastTarget)
            self.lastTarget = now
            self.onFrame?(min(dt, 1.0 / 12))
        }
        RunLoop.main.add(t, forMode: .common)
        fallback = t
    }

    func setFrameRate(_ fps: Float) {
        guard fps != currentFPS else { return }
        currentFPS = fps
        if #available(macOS 14.0, *), let l = link as? CADisplayLink {
            // A hint that saves wakeups where the display honors it. Actual frames are decided in step(_:).
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: fps, preferred: fps)
        } else if fallback != nil {
            setFallback(fps: fps)
        }
    }

    var clockPaused: Bool {
        get {
            if #available(macOS 14.0, *), let l = link as? CADisplayLink { return l.isPaused }
            return fallback == nil
        }
        set {
            guard newValue != clockPaused else { return }
            if #available(macOS 14.0, *), let l = link as? CADisplayLink {
                l.isPaused = newValue
                lastTarget = 0
            } else if newValue {
                fallback?.invalidate()
                fallback = nil
            } else {
                setFallback(fps: max(currentFPS, 20))
            }
        }
    }

    func setInteractive(_ on: Bool) {
        window.ignoresMouseEvents = !on
        window.invalidateCursorRects(for: view)
        window.acceptsMouseMovedEvents = on
    }

    func close() {
        if #available(macOS 14.0, *), let l = link as? CADisplayLink { l.invalidate() }
        fallback?.invalidate()
        fallback = nil
        link = nil
        window.orderOut(nil)
        window.close()
    }
}
