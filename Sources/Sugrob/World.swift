import AppKit
import simd

struct FrameInfo {
    var dt: Float
    var mouse: V2        // global, top-left origin
    var mouseVelocity: V2
    var play: Bool
    var tool: Tool
}

struct Powder {
    var x: Float, y: Float, vx: Float, vy: Float
    var size: Float, age: Float, life: Float, deposit: Float, gravity: Float
    var sprite: Sprite = .dot
    var tint: SIMD4<Float> = SIMD4(repeating: 1)
}

struct Splat { var x: Float, y: Float, rot: Float, size: Float, age: Float, life: Float }

struct Bulb { var x: Float, y: Float, phase: Float; var tint: SIMD3<Float> }

let zFront: Float = 0.02
let zBars: Float = 0.06

let warmWhite = SIMD3<Float>(1.0, 0.8, 0.5)
let warmRed = SIMD3<Float>(1.0, 0.26, 0.22)
let warmGold = SIMD3<Float>(1.0, 0.66, 0.18)

final class World {
    let screen: NSScreen
    let cgFrame: CGRect
    let size: V2
    let backing: Float
    let primary: Bool

    private(set) var time: Float = 0
    /// Drives the crests and the snow shader. It only advances during a gust, so calm snow is a still picture.
    private(set) var windTime: Float = 0
    private(set) var gust: Float = 0
    private var gustLength: Float = 1
    private var gustDirection: Float = 1
    var hidden = false
    /// The live app hands twinkling lights to Core Animation. Offscreen renders draw them here.
    var lightsInMetal = true
    /// Set whenever the picture changed without anything being in motion.
    var needsRedraw = true
    private(set) var garlandVersion = 0

    var menuBarH: Float = 0
    var dockH: Float = 0
    var dockWidth: Float?

    var ground: Surface
    var windowSurfaces: [CGWindowID: Surface] = [:]
    var active: [Surface] = []
    /// Surfaces whose top edge can actually be seen. Only these receive or draw snow.
    var landable: [Surface] = []
    var rects: [Rect2] = []

    var powder: [Powder] = []
    var splats: [Splat] = []
    var bulbs: [Bulb] = []
    var wire: [V2] = []

    var balls: [Ball] = []
    var men: [Snowman] = []
    var lumps: [Lump] = []
    var held: HeldBall?
    var carried: Lump?
    var grabbed: Snowman?

    var pointer = V2(-1000, -1000)
    var pointerVelocity = V2.zero
    var pointerInside = false
    var firstSync = true
    /// Set when a sync finds a window in a new place. Read and cleared by the coordinator.
    var windowMoved = false
    private var spindriftDebt: Float = 0
    /// How much snow each tier carries, from the top of the tree down.
    private(set) var treeSnow: [Float] = [1, 1, 1]
    private var treeRegrowIn: [Float] = [0, 0, 0]
    private(set) var treeTilt: Float = 0
    private var treeTiltV: Float = 0
    private var treeWasTouched = false
    private(set) var fireworks: Float = 0
    private var nextBurst: Float = 0

    private let settings = Settings.shared
    private var appliedAmount: Float

    init(screen: NSScreen, primary: Bool) {
        self.screen = screen
        self.primary = primary
        let primaryH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        cgFrame = CGRect(x: screen.frame.minX, y: primaryH - screen.frame.maxY,
                         width: screen.frame.width, height: screen.frame.height)
        size = V2(Float(screen.frame.width), Float(screen.frame.height))
        backing = Float(screen.backingScaleFactor)
        appliedAmount = Settings.shared.amount
        ground = Surface(kind: .ground, x: 0, y: size.y, width: size.x, capHeight: 20 + 60 * Settings.shared.amount)
        ground.prewarm(0.8, 0.9)
        refreshBars()
        active = [ground]
        landable = [ground]
    }

    // MARK: Geometry

    func refreshBars() {
        let menu = Float(screen.frame.maxY - screen.visibleFrame.maxY)
        if abs(menu - menuBarH) > 0.5 || bulbs.isEmpty {
            menuBarH = menu
            buildGarland()
        }
        dockH = Float(screen.visibleFrame.minY - screen.frame.minY)
        let oldDock = dockWidth
        dockWidth = dockH > 8 ? DockEstimator.width().map { min($0, size.x * 0.8) } : nil
        if abs((oldDock ?? -1) - (dockWidth ?? -1)) > 1 { needsRedraw = true }
        // The width is an estimate, so the valley gets some margin past the Dock's ends.
        let valley = dockWidth.map { ((size.x - $0) / 2 - 36)...((size.x + $0) / 2 + 36) }
        if abs((ground.valley?.lowerBound ?? -1) - (valley?.lowerBound ?? -1)) > 6 {
            ground.valley = valley
            ground.rebuildShape()
            needsRedraw = true
        }
    }

    /// One thin strand that sags between evenly spaced anchor points below the menu bar.
    private func buildGarland() {
        bulbs.removeAll()
        wire.removeAll()
        garlandVersion += 1
        needsRedraw = true
        let spans = max(3, Int((size.x / 300).rounded()))
        let span = size.x / Float(spans)
        let top = menuBarH + 0.5
        func y(_ x: Float) -> Float {
            let t = (x / span).truncatingRemainder(dividingBy: 1)
            return top + 16 * 4 * t * (1 - t)
        }
        var x: Float = 0
        while x <= size.x {
            wire.append(V2(x, y(x)))
            x += 10
        }
        wire.append(V2(size.x, y(size.x - 0.01)))

        let spacing = span / 7
        var i = 0
        var bx = spacing / 2
        while bx < size.x {
            let tint = i % 6 == 3 ? warmRed : (i % 6 == 0 ? warmGold : warmWhite)
            bulbs.append(Bulb(x: bx, y: y(bx) + 3.5, phase: Float(i) * 0.9, tint: tint))
            bx += spacing
            i += 1
        }
    }

    /// The tree stands on the open drift to the right of the Dock.
    var treeX: Float {
        guard let w = dockWidth else { return size.x * 0.88 }
        return ((size.x + w) / 2 + size.x) / 2
    }

    // MARK: Window sync

    @inline(__always) func zFor(_ order: Int) -> Float {
        0.1 + 0.8 * Float(order + 1) / Float(rects.count + 2)
    }

    /// Returns true when a full-screen app covers this display.
    func syncWindows(_ infos: [WindowInfo], pollDt: Float, existing: () -> Set<CGWindowID>) -> Bool {
        let oldRects = rects
        let oldLandable = landable.count
        rects.removeAll(keepingCapacity: true)
        var local: [(WindowInfo, Rect2)] = []
        for info in infos where info.frame.intersects(cgFrame) {
            let r = Rect2(x: Float(info.frame.minX - cgFrame.minX), y: Float(info.frame.minY - cgFrame.minY),
                          w: Float(info.frame.width), h: Float(info.frame.height))
            rects.append(r)
            local.append((info, r))
        }
        let fullscreen = rects.first.map { abs($0.w - size.x) < 2 && abs($0.h - size.y) < 2 && abs($0.x) < 2 && abs($0.y) < 2 } ?? false

        var next: [Surface] = []
        var seen = Set<CGWindowID>()
        if settings.snowOnWindows {
            for (order, (info, r)) in local.enumerated() where r.y > menuBarH + 6 && r.y < size.y - 40 {
                seen.insert(info.id)
                let surface: Surface
                if let s = windowSurfaces[info.id] {
                    surface = s
                    s.active = true
                    let dx = r.x - s.x, dy = r.y - s.y
                    if abs(r.w - s.width) > 2 { s.resize(width: r.w) }
                    if dx != 0 || dy != 0 {
                        windowMoved = true
                        let speed = hypot(dx, dy) / max(pollDt, 1.0 / 120)
                        if speed > 900 { shed(s, dx: dx / max(pollDt, 1.0 / 120), speed: speed) }
                        s.x = r.x
                        s.y = r.y
                    }
                } else {
                    surface = Surface(kind: .window, x: r.x, y: r.y, width: r.w, capHeight: windowCap)
                    if firstSync { surface.prewarm(0.6, 0.9) } else { surface.growIn(rnd(0.6, 0.9)) }
                    windowSurfaces[info.id] = surface
                }
                surface.order = order
                surface.z = zFor(order) - 0.0002
                next.append(surface)
            }
        }

        var known: Set<CGWindowID>?
        for (id, s) in windowSurfaces where !seen.contains(id) && s.active {
            if known == nil { known = existing() }
            if known!.contains(id) {
                s.active = false
            } else {
                collapse(s)
                windowSurfaces[id] = nil
            }
        }

        ground.order = 0
        ground.z = zBars - 0.004
        next.append(ground)
        active = next
        landable = next.filter { s in
            guard s.kind == .window else { return true }
            return stride(from: s.x + 6, to: s.x + s.width, by: 28).contains { !isOccluded($0, s.y - 1, order: s.order) }
        }
        firstSync = false
        // Any change in window layout changes what snow is visible, even if nothing is moving.
        let same = oldRects.count == rects.count && oldLandable == landable.count && zip(oldRects, rects).allSatisfy {
            $0.x == $1.x && $0.y == $1.y && $0.w == $1.w && $0.h == $1.h
        }
        if !same { needsRedraw = true }
        return fullscreen
    }

    private func shed(_ s: Surface, dx: Float, speed: Float) {
        let frac = clampf((speed - 900) / 2600, 0.08, 0.9)
        var i = 0
        while i < s.cols {
            let amount = s.h[i] * frac
            s.h[i] -= amount
            if amount > 0.3 && i % 2 == 0 {
                spawnPowder(x: s.x + Float(i) * Surface.cw, y: s.y - s.h[i], vx: dx * 0.2 + rnd(-30, 30), vy: rnd(-40, 40),
                            size: rnd(1.6, 3.6), life: 3, deposit: amount * 2, gravity: 560)
            }
            i += 1
        }
        // There is no snowfall to refill it, so the window's snow grows back by itself.
        s.noteDent()
        s.dirty = true
    }

    private func collapse(_ s: Surface) {
        s.alive = false
        var i = 0
        while i < s.cols {
            if s.h[i] > 0.3 {
                spawnPowder(x: s.x + Float(i) * Surface.cw, y: s.y - s.h[i] * rnd(0, 1), vx: rnd(-20, 20), vy: rnd(-20, 40),
                            size: rnd(1.6, 3.6), life: 3, deposit: s.h[i] * 3, gravity: 560)
            }
            i += 3
        }
    }

    @inline(__always) func isOccluded(_ x: Float, _ y: Float, order: Int) -> Bool {
        let n = min(order, rects.count)
        var i = 0
        while i < n {
            if rects[i].contains(x, y) { return true }
            i += 1
        }
        return false
    }

    @inline(__always) func landing(x: Float, from y0: Float, to y1: Float) -> Surface? {
        for s in landable {
            guard x >= s.x, x < s.x + s.width else { continue }
            let top = s.top(at: x)
            if y0 <= top && y1 >= top && !isOccluded(x, top, order: s.order) { return s }
        }
        return nil
    }

    func surfaceBelow(x: Float, y: Float) -> Surface {
        var best = ground
        var bestTop = Float.greatestFiniteMagnitude
        for s in active {
            guard x >= s.x, x < s.x + s.width else { continue }
            let top = s.top(at: x)
            if top >= y - 24, top < bestTop, !isOccluded(x, top, order: s.order) {
                best = s
                bestTop = top
            }
        }
        return best
    }

    // MARK: Particles

    func spawnPowder(x: Float, y: Float, vx: Float, vy: Float, size: Float, life: Float, deposit: Float, gravity: Float,
                     sprite: Sprite = .dot, tint: SIMD4<Float> = SIMD4(repeating: 1)) {
        guard powder.count < 1400 else { return }
        powder.append(Powder(x: x, y: y, vx: vx, vy: vy, size: size, age: 0, life: life, deposit: deposit, gravity: gravity, sprite: sprite, tint: tint))
    }

    func burst(x: Float, y: Float, count: Int, speed: Float, deposit: Float = 0.5) {
        for _ in 0..<count {
            let a = rnd(0, .pi * 2), v = rnd(speed * 0.25, speed)
            spawnPowder(x: x, y: y, vx: cos(a) * v, vy: sin(a) * v - speed * 0.3, size: rnd(1.6, 4), life: 1.6, deposit: deposit, gravity: 700)
        }
    }

    private var groundCap: Float { 20 + 60 * settings.amount }
    private var windowCap: Float { 4 + 8 * settings.amount }

    /// The amount also sets drift height. Existing snow is rescaled so the change shows at once.
    private func applyAmount() {
        guard abs(appliedAmount - settings.amount) > 0.001 else { return }
        appliedAmount = settings.amount
        func rescale(_ s: Surface, to cap: Float) {
            let ratio = cap / max(s.capHeight, 0.01)
            for i in 0..<s.cols {
                s.h[i] *= ratio
                s.rest[i] *= ratio
            }
            s.capHeight = cap
            s.rebuildShape()
            s.relax()
        }
        rescale(ground, to: groundCap)
        for s in windowSurfaces.values { rescale(s, to: windowCap) }
    }

    /// A few seconds of wind. Between gusts the snow does not move at all.
    func startGust(seconds: Float = 3.6) {
        gust = seconds
        gustLength = seconds
        gustDirection = frand() < 0.5 ? -1 : 1
    }

    /// Rises and falls smoothly over the gust, so the wind never starts or stops with a jerk.
    private var gustStrength: Float {
        guard gust > 0 else { return 0 }
        let s = sin(.pi * (1 - gust / gustLength))
        return s * s
    }

    /// The gust shifts the crests and lifts thin streams of powder off them.
    private func updateGust(dt: Float) {
        guard gust > 0 else { return }
        let strength = gustStrength
        gust = max(0, gust - dt)
        windTime += dt * strength * 4 * gustDirection
        spindriftDebt += dt * strength * 120 * (0.4 + settings.amount)
        let windows = landable.filter { $0.kind == .window }
        let direction = gustDirection
        while spindriftDebt >= 1 {
            spindriftDebt -= 1
            let s = (!windows.isEmpty && frand() < 0.25) ? windows[Int(rnd(0, Float(windows.count) - 0.01))] : ground
            let column = Int(rnd(0, Float(s.cols) - 0.01))
            guard s.soft[column] > 3 else { continue }
            let x = s.x + Float(column) * Surface.cw
            spawnPowder(x: x, y: s.top(at: x) + 1, vx: direction * rnd(45, 125), vy: rnd(-26, -6), size: rnd(1.4, 3), life: rnd(1, 2.2),
                        deposit: 0, gravity: 12, tint: SIMD4(repeating: 0.8))
        }
    }

    /// The cursor leaves a soft trough in any drift it passes through.
    private func plow(_ p: V2, velocity: V2) {
        let r: Float = 12
        for s in landable where s.maxH > 0.3 {
            guard p.x > s.x - r, p.x < s.x + s.width + r, p.y > s.y - s.maxH * 1.3 - r, p.y < s.y + r,
                  !isOccluded(p.x, s.y - 1, order: s.order) else { continue }
            var dented = false
            for i in s.column(p.x - r)...s.column(p.x + r) {
                let dx = s.x + Float(i) * Surface.cw - p.x
                let t = r * r - dx * dx
                guard t > 0 else { continue }
                let allowed = max(0, s.y - (p.y + t.squareRoot()))
                guard s.h[i] > allowed else { continue }
                let dh = s.h[i] - allowed
                s.h[i] = allowed
                if frand() < 0.16 {
                    spawnPowder(x: s.x + Float(i) * Surface.cw, y: s.y - allowed, vx: velocity.x * 0.3 + rnd(-30, 30), vy: rnd(-150, -50),
                                size: rnd(1.6, 3.4), life: 1.6, deposit: min(4, dh * 3), gravity: 620)
                }
                dented = true
            }
            if dented { s.noteDent() }
            s.dirty = true
        }
    }

    private func updatePowder(dt: Float) {
        var i = 0
        while i < powder.count {
            powder[i].age += dt
            powder[i].vy += powder[i].gravity * dt
            powder[i].vx *= max(0, 1 - dt * 0.9)
            let y0 = powder[i].y
            powder[i].x += powder[i].vx * dt
            powder[i].y += powder[i].vy * dt
            var gone = powder[i].age > powder[i].life || powder[i].y > size.y + 20
            if powder[i].deposit > 0, powder[i].vy > 0, !gone, let s = landing(x: powder[i].x, from: y0, to: powder[i].y) {
                s.deposit(at: powder[i].x, amount: powder[i].deposit)
                gone = true
            }
            if gone { powder.swapAt(i, powder.count - 1); powder.removeLast() } else { i += 1 }
        }
    }

    private func updateSplats(dt: Float) {
        var i = 0
        while i < splats.count {
            splats[i].age += dt
            splats[i].y += dt * (1 + splats[i].age * 1.1)
            if splats[i].age > splats[i].life { splats.swapAt(i, splats.count - 1); splats.removeLast() } else { i += 1 }
        }
    }

    /// Only a cursor close to snow can change anything worth extra frames.
    var pointerNearSnow: Bool { pointerInside && isNearSnow(pointer) }

    /// True only where the cursor can actually disturb something: on a drift, on a window's snow or on the tree.
    func isNearSnow(_ p: V2) -> Bool {
        let margin: Float = 18
        if p.y > ground.top(at: p.x) - margin { return true }
        if primary && settings.tree && abs(p.x - treeX) < treeW / 2 + margin && p.y > treeBase - treeH - margin && p.y < treeBase { return true }
        if men.contains(where: { abs(p.x - $0.x) < $0.R + 60 && p.y > $0.y - $0.height - 60 }) { return true }
        return landable.contains {
            $0.kind == .window && $0.maxH > 0.3 && abs(p.y - $0.y) < margin + $0.maxH && p.x > $0.x - margin && p.x < $0.x + $0.width + margin
        }
    }

    func isNearSnow(global g: V2) -> Bool {
        let p = V2(g.x - Float(cgFrame.minX), g.y - Float(cgFrame.minY))
        guard p.x >= 0, p.y >= 0, p.x <= size.x, p.y <= size.y else { return false }
        return isNearSnow(p)
    }

    /// Why the scene still needs frames, or nil when it is a still picture.
    var unsettledReason: String? {
        if needsRedraw { return "redraw" }
        if gust > 0 { return "gust" }
        if fireworks > 0 { return "fireworks" }
        if !powder.isEmpty { return "powder" }
        if !splats.isEmpty { return "splats" }
        if !balls.isEmpty || held != nil || carried != nil || grabbed != nil { return "play" }
        if abs(treeTilt) > 0.002 || abs(treeTiltV) > 0.02 { return "tree sway" }
        if treeSnow.contains(where: { $0 < 1 }) { return "tree snow" }
        if active.contains(where: { $0.healing }) { return "healing" }
        if active.contains(where: { $0.dirty }) { return "slumping" }
        if men.contains(where: { !$0.restful }) { return "snowman" }
        if lumps.contains(where: { !$0.restful }) { return "ball" }
        if abs(appliedAmount - settings.amount) > 0.001 { return "amount" }
        return nil
    }

    var settled: Bool { unsettledReason == nil }

    /// True when the only motion left is snow slowly growing back, which looks the same at a few frames a second.
    var onlySlowMotion: Bool {
        gust <= 0 && fireworks <= 0 && powder.isEmpty && splats.isEmpty && balls.isEmpty && held == nil && carried == nil && grabbed == nil
            && abs(treeTilt) <= 0.002 && abs(treeTiltV) <= 0.02 && !men.contains(where: { !$0.restful }) && !lumps.contains(where: { !$0.restful })
    }

    // MARK: Fireworks

    func startFireworks(seconds: Float) {
        fireworks = seconds
        nextBurst = 0
    }

    private func updateFireworks(dt: Float) {
        guard fireworks > 0 else { return }
        fireworks = max(0, fireworks - dt)
        nextBurst -= dt
        guard nextBurst <= 0 else { return }
        nextBurst = rnd(0.45, 1.0)
        let cx = rnd(size.x * 0.15, size.x * 0.85), cy = rnd(menuBarH + 90, size.y * 0.5)
        let color = [warmGold, warmWhite, warmRed][Int(rnd(0, 2.99))]
        let tint = SIMD4(color.x, color.y, color.z, 1)
        spawnPowder(x: cx, y: cy, vx: 0, vy: 0, size: 280, life: 0.4, deposit: 0, gravity: 0, sprite: .glow,
                    tint: SIMD4(color.x * 0.35, color.y * 0.35, color.z * 0.35, 0.06))
        for i in 0..<64 {
            let a = Float(i) / 64 * .pi * 2 + rnd(-0.04, 0.04)
            let v = rnd(150, 290)
            spawnPowder(x: cx, y: cy, vx: cos(a) * v, vy: sin(a) * v, size: rnd(2.6, 4.4), life: rnd(1.1, 1.7), deposit: 0, gravity: 95, tint: tint)
        }
    }

    func clearSnowmen() {
        needsRedraw = true
        men.removeAll()
        lumps.removeAll()
        carried = nil
        splats.removeAll()
    }

    // MARK: Frame

    func update(_ f: FrameInfo) {
        let dt = f.dt
        time += dt
        needsRedraw = false
        let p = V2(f.mouse.x - Float(cgFrame.minX), f.mouse.y - Float(cgFrame.minY))
        pointer = p
        pointerVelocity = f.mouseVelocity
        pointerInside = p.x >= 0 && p.y >= 0 && p.x <= size.x && p.y <= size.y

        applyAmount()
        if pointerInside && !f.play && simd_length(f.mouseVelocity) > 60 { plow(p, velocity: f.mouseVelocity) }
        for s in active {
            s.time = windTime
            s.heal(dt: dt)
            s.relax()
        }
        updateGust(dt: dt)
        updateTree(dt: dt, velocity: f.mouseVelocity)
        updatePowder(dt: dt)
        updateSplats(dt: dt)
        updateFireworks(dt: dt)
        updatePlay(f)
    }

    // MARK: Output

    func fill(_ k: Sink) {
        for (i, r) in rects.enumerated() { k.occlude(r, z: zFor(i)) }
        if menuBarH > 0 { k.occlude(Rect2(x: 0, y: 0, w: size.x, h: menuBarH), z: zBars) }
        if let w = dockWidth {
            k.occlude(Rect2(x: (size.x - w) / 2 - 8, y: size.y - dockH + 3, w: w + 16, h: dockH), z: zBars)
        }

        // The tree stands between the far ridge and the near drift, which covers the foot of its trunk.
        if ground.maxH > 0.1 { emitStrip(ground, k, back: true) }
        k.farStrips = k.strips.count
        if primary && settings.tree { fillTree(k) }
        k.behindCount = k.spriteCount

        for s in landable where s.maxH > 0.1 { emitStrip(s, k, back: false) }
        if primary && settings.tree {
            // A pool of warm light on the snow under the tree.
            k.put(.glow, treeX, treeBase - 4, 210, 52, z: zBars - 0.005, c: SIMD4(warmGold.x * 0.2, warmGold.y * 0.2, warmGold.z * 0.2, 0))
        }

        fillPlay(k)
        if settings.garland { fillGarland(k) }
        for p in powder {
            let a = 1 - smooth(p.life * 0.55, p.life, p.age)
            k.put(p.sprite, p.x, p.y, p.size, p.size, z: zFront, c: p.tint * a)
        }
        for s in splats {
            let a = (1 - smooth(s.life * 0.6, s.life, s.age)) * 0.95
            let pop = easeOutBack(s.age / 0.1)
            k.put(.splat, s.x, s.y, s.size * pop, s.size * pop, rot: s.rot, z: zFront, c: SIMD4(repeating: a))
        }
    }

    private func emitStrip(_ s: Surface, _ k: Sink, back: Bool) {
        guard k.vertCount + s.cols * 2 < k.vertCap else { return }
        let start = k.vertCount
        let drape: Float = (s.kind == .ground || back) ? 0 : 1.5
        let shadow: Float = (s.kind == .ground || back) ? 0 : 4
        let tint = SIMD4<Float>(back ? 1 : 0, 0, 0, 0)
        for i in 0..<s.cols {
            let vh = back ? s.backVisual(i) : s.visual(i)
            let next = back ? s.backVisual(i + 4) : s.visual(i + 4)
            let prev = back ? s.backVisual(i - 4) : s.visual(i - 4)
            let wx = s.x + Float(i) * Surface.cw
            let topY = s.y - vh
            let bottomY = s.y + drape + shadow
            let q = SIMD4<Float>(Float(i) * Surface.cw + s.seed, vh + drape, shadow, (next - prev) / (8 * Surface.cw))
            k.verts[k.vertCount] = SnowVertex(p: SIMD4(wx, topY - 2, -2, s.z), q: q, r: tint)
            k.verts[k.vertCount + 1] = SnowVertex(p: SIMD4(wx, bottomY, bottomY - topY, s.z), q: q, r: tint)
            k.vertCount += 2
        }
        k.strips.append((start, s.cols * 2))
    }

    private func light(_ k: Sink, _ x: Float, _ y: Float, _ tint: SIMD3<Float>, level: Float, core: Float, halo: Float, z: Float) {
        k.put(.glow, x, y, halo, halo, z: z, c: SIMD4(tint.x * level * 0.8, tint.y * level * 0.8, tint.z * level * 0.8, level * 0.12))
        let bright = tint + (SIMD3<Float>(repeating: 1) - tint) * 0.6
        k.put(.bulb, x, y, core, core, z: z, c: SIMD4(bright.x * level, bright.y * level, bright.z * level, 1))
    }

    private func fillGarland(_ k: Sink) {
        let z = zBars - 0.002
        for i in 0..<(wire.count - 1) {
            let a = wire[i], b = wire[i + 1]
            let d = b - a
            k.put(.wire, (a.x + b.x) / 2, (a.y + b.y) / 2, simd_length(d) + 0.5, 1.2, rot: atan2(d.y, d.x), z: z, c: SIMD4(0.3, 0.3, 0.3, 0.55))
        }
        guard lightsInMetal else { return }
        for b in bulbs {
            light(k, b.x, b.y, b.tint, level: 0.68 + 0.32 * sin(time * 0.9 + b.phase), core: 5.5, halo: 40, z: z)
        }
    }

    // MARK: The tree

    let treeW: Float = 110
    let treeH: Float = 154
    /// Positions of the tree lights as fractions of its width (from the trunk) and height (from the top).
    static let treeLights: [(Float, Float)] = [
        (-0.3, 0.8), (-0.14, 0.84), (0.04, 0.82), (0.2, 0.78), (0.33, 0.73),
        (-0.21, 0.57), (-0.05, 0.6), (0.1, 0.58), (0.22, 0.54),
        (-0.1, 0.36), (0.04, 0.38), (0.12, 0.32),
    ]
    /// Sprite height fractions of the visible tiers, from the top of the tree down.
    private let treeBands: [(Float, Float)] = [(0.0, 0.44), (0.44, 0.68), (0.68, 0.93)]
    private let bandHalfWidths: [Float] = [0.26, 0.37, 0.48]

    var treeBase: Float { ground.top(at: treeX) + 12 }

    private func treeTouched(_ p: V2) -> Bool {
        let top = treeBase - treeH
        let f = (p.y - top) / treeH
        guard f >= 0, f <= 0.95 else { return false }
        return abs(p.x - treeX) <= treeW * (0.08 + 0.42 * f)
    }

    private func updateTree(dt: Float, velocity: V2) {
        treeTiltV += (-treeTilt * 70 - treeTiltV * 5) * dt
        treeTilt += treeTiltV * dt

        let touching = primary && settings.tree && pointerInside && treeTouched(pointer)
        if touching && !treeWasTouched { shakeTree(velocity: velocity) }
        treeWasTouched = touching

        for i in 0..<3 {
            if treeRegrowIn[i] > 0 {
                treeRegrowIn[i] -= dt
            } else {
                treeSnow[i] = min(1, treeSnow[i] + dt / 5)
            }
        }
    }

    /// Knocks the snow off every tier. It returns from the top down after a pause.
    private func shakeTree(velocity: V2) {
        treeTiltV += (velocity.x >= 0 ? 1 : -1) * 1.7
        let x = treeX, top = treeBase - treeH
        for i in 0..<3 where treeSnow[i] > 0.05 {
            let (v0, v1) = treeBands[i]
            let n = Int(34 * treeSnow[i])
            for _ in 0..<n {
                let f = rnd(v0 + 0.03, v1)
                let spread = bandHalfWidths[i] * treeW * (f - v0 + 0.1) / (v1 - v0 + 0.1)
                spawnPowder(x: x + rnd(-spread, spread), y: top + f * treeH, vx: rnd(-55, 55) + velocity.x * 0.08, vy: rnd(-70, 20),
                            size: rnd(2, 4.6), life: 1.8, deposit: 0.5, gravity: 620)
            }
            treeSnow[i] = 0
        }
        for i in 0..<3 where treeRegrowIn[i] <= 0 { treeRegrowIn[i] = 2.2 + Float(i) * 1.4 }
    }

    private func fillTree(_ k: Sink) {
        let x = treeX
        let z = ground.z
        let w = treeW, h = treeH
        let base = treeBase
        let cs = cos(treeTilt), sn = sin(treeTilt)
        // Everything sways around the foot of the trunk.
        func point(_ lx: Float, _ ly: Float) -> V2 { V2(x + lx * cs - ly * sn, base + lx * sn + ly * cs) }

        let center = point(0, -h / 2)
        k.put(.tree, center.x, center.y, w, h, rot: treeTilt, z: z)
        for (i, band) in treeBands.enumerated() where treeSnow[i] > 0.01 {
            let bandH = (band.1 - band.0) * h
            let c = point(0, -h + (band.0 + band.1) / 2 * h)
            k.putBand(.treeSnow, from: band.0, to: band.1, c.x, c.y, w, bandH, rot: treeTilt, z: z, c: SIMD4(repeating: treeSnow[i]))
        }

        guard lightsInMetal else { return }
        for (i, l) in World.treeLights.enumerated() {
            let tint = i % 4 == 1 ? warmRed : warmWhite
            let p = point(l.0 * w, -h + l.1 * h)
            light(k, p.x, p.y, tint, level: 0.65 + 0.35 * sin(time * 1.2 + Float(i) * 1.7), core: 3.6, halo: 24, z: z)
        }
        let star = point(0, -h + 0.05 * h)
        light(k, star.x, star.y, warmGold, level: 0.8 + 0.2 * sin(time * 0.7), core: 0.01, halo: 60, z: z)
    }
}
