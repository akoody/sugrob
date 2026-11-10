import AppKit
import simd

struct HeldBall { var pos: V2; var r: Float }

struct Ball {
    var pos: V2
    var vel: V2
    var r: Float
    var age: Float = 0
    var ignore: Rect2?
    var glass = false
}

/// A hand-rolled ball, or a stack of up to two, waiting to become a snowman.
final class Lump {
    enum State { case idle, carried, falling }

    /// Radii from bottom to top.
    var parts: [Float]
    var surface: Surface?
    var offset: Float = 0
    var x: Float
    var y: Float
    var vx: Float = 0
    var vy: Float = 0
    var state: State
    var rolling = false

    /// True when nothing about this pile will change without input.
    var restful: Bool {
        guard state == .idle, abs(squash) < 0.004, abs(squashV) < 0.03 else { return false }
        guard let s = surface, s.active else { return true }
        return abs(s.top(at: x) + 3 - y) < 0.3
    }
    var squash: Float = 0
    var squashV: Float = 0

    init(x: Float, y: Float, radius: Float, state: State) {
        self.x = x
        self.y = y
        parts = [radius]
        self.state = state
    }

    func centers() -> [(V2, Float)] {
        var result: [(V2, Float)] = []
        var cy = y - parts[0] * 0.9
        for (i, r) in parts.enumerated() {
            if i > 0 { cy -= (parts[i - 1] + r) * 0.74 }
            result.append((V2(x, cy), r))
        }
        return result
    }

    func hit(point: V2) -> Bool {
        centers().contains { simd_distance($0.0, point) < $0.1 + 4 }
    }
}

final class Snowman {
    enum State { case idle, held, falling }

    var surface: Surface?
    var offset: Float = 0
    var x: Float
    var y: Float
    var vx: Float = 0
    var vy: Float = 0
    var R: Float
    var r2: Float
    var r3: Float
    var state: State = .idle
    var build: Float
    var tilt: Float = 0
    var tiltV: Float = 0
    var squash: Float = 0
    var squashV: Float = 0
    var hp = 3
    var blink = rnd(1, 5)

    /// True when nothing about this snowman will change without input.
    var restful: Bool {
        guard state == .idle, finished, blink >= 0 else { return false }
        guard abs(tilt) < 0.004, abs(tiltV) < 0.03, abs(squash) < 0.004, abs(squashV) < 0.03 else { return false }
        guard let s = surface, s.active else { return true }
        return abs(s.top(at: x) + 3 - y) < 0.3
    }
    var finished = false

    init(x: Float, y: Float, R: Float, build: Float) {
        self.x = x
        self.y = y
        self.R = R
        self.build = build
        r2 = R * 0.7
        r3 = R * 0.5
    }

    var y1: Float { -R * 0.9 }
    var y2: Float { y1 - (R + r2) * 0.72 }
    var y3: Float { y2 - (r2 + r3) * 0.76 }
    var height: Float { -y3 + r3 }

    func parts() -> [(V2, Float)] {
        [(V2(x, y + y1), R), (V2(x, y + y2), r2), (V2(x, y + y3), r3)]
    }

    func hit(point: V2) -> Bool {
        parts().contains { simd_distance($0.0, point) < $0.1 + 3 }
    }
}

extension World {
    // MARK: Input

    func pointerDown(_ p: V2, tool: Tool) {
        switch tool {
        case .snowball:
            held = HeldBall(pos: p, r: 8)
        case .snowman:
            if let m = men.last(where: { $0.hit(point: p) }) {
                grabbed = m
                m.state = .held
                m.surface = nil
                Sound.shared.play(.pop, gain: 0.3)
            } else if let l = lumps.last(where: { $0.hit(point: p) }) {
                carried = l
                l.state = .carried
                l.surface = nil
                l.rolling = false
                Sound.shared.play(.pop, gain: 0.3)
            } else {
                let l = Lump(x: p.x, y: p.y, radius: 14, state: .carried)
                if lumps.count >= 12 { lumps.removeFirst() }
                lumps.append(l)
                carried = l
                moveCarried(l, to: p)
                Sound.shared.play(.crunch, gain: 0.2)
            }
        }
    }

    func pointerDragged(from a: V2, to p: V2, velocity: V2, tool: Tool) {
        switch tool {
        case .snowball:
            held?.pos = p
        case .snowman:
            if let m = grabbed {
                m.x = p.x
                m.y = p.y + m.height * 0.5
            } else if let l = carried {
                moveCarried(l, to: p)
            }
        }
    }

    func pointerUp(_ p: V2, velocity: V2, tool: Tool) {
        switch tool {
        case .snowball:
            guard let h = held else { return }
            held = nil
            throwBall(h, velocity: velocity)
        case .snowman:
            if let m = grabbed {
                grabbed = nil
                m.vx = clampf(velocity.x, -1500, 1500)
                m.vy = clampf(velocity.y, -1500, 1500)
                m.state = .falling
            } else if let l = carried {
                carried = nil
                release(l, velocity: velocity)
            }
        }
    }

    private func throwBall(_ h: HeldBall, velocity: V2) {
        let speed = simd_length(velocity)
        if speed < 190 {
            balls.append(Ball(pos: h.pos, vel: .zero, r: h.r, glass: true))
        } else {
            let scale = min(2800, speed * 1.1) / speed
            balls.append(Ball(pos: h.pos, vel: velocity * scale, r: h.r, ignore: rects.first { $0.contains(h.pos.x, h.pos.y) }))
            Sound.shared.play(.whoosh, gain: 0.25)
        }
    }

    func addSplat(_ x: Float, _ y: Float, size: Float) {
        if splats.count >= 24 { splats.removeFirst() }
        splats.append(Splat(x: x, y: y, rot: rnd(0, 6.28), size: size, age: 0, life: rnd(6, 9)))
    }

    // MARK: Building snowmen by hand

    /// Near snow a single ball rolls and grows. Lifted away from it, the ball is simply carried.
    private func moveCarried(_ l: Lump, to p: V2) {
        let r = l.parts[0]
        let s = surfaceBelow(x: p.x, y: p.y)
        let top = s.top(at: p.x)
        l.rolling = l.parts.count == 1 && p.y >= top - r * 2.2
        guard l.rolling else {
            l.x = p.x
            l.y = p.y + r * 0.9
            return
        }
        let dx = p.x - l.x
        var consumed: Float = 0
        for i in s.column(p.x - r * 0.6)...s.column(p.x + r * 0.6) {
            let take = min(s.h[i], abs(dx) * 0.05)
            s.h[i] -= take
            consumed += take * Surface.cw
        }
        if consumed > 0 {
            s.dirty = true
            s.noteDent()
            l.parts[0] = min(58, (r * r + consumed * 3).squareRoot())
        }
        l.x = p.x
        l.y = top + 3
        l.surface = s
    }

    func stackTarget(for l: Lump) -> Lump? {
        guard !l.rolling, let bottom = l.centers().first else { return nil }
        var best: Lump?
        var bestDistance = Float.greatestFiniteMagnitude
        for t in lumps where t !== l && t.state == .idle && t.parts.count + l.parts.count <= 3 {
            guard let top = t.centers().last, bottom.0.y < top.0.y else { continue }
            let d = simd_distance(bottom.0, top.0)
            if d < top.1 + bottom.1 + 34, d < bestDistance {
                best = t
                bestDistance = d
            }
        }
        return best
    }

    private func release(_ l: Lump, velocity: V2) {
        if let target = stackTarget(for: l) {
            stack(l, on: target)
        } else if l.rolling, let s = l.surface {
            l.offset = l.x - s.x
            l.state = .idle
            l.rolling = false
        } else {
            l.surface = nil
            l.rolling = false
            l.vx = clampf(velocity.x, -1000, 1000)
            l.vy = clampf(velocity.y, -1000, 1000)
            l.state = .falling
        }
    }

    private func stack(_ l: Lump, on target: Lump) {
        target.parts.append(contentsOf: l.parts)
        target.parts.sort(by: >)
        lumps.removeAll { $0 === l }
        target.squashV += 5
        Sound.shared.play(.pop, gain: 0.4)
        guard target.parts.count >= 3 else { return }

        // Three balls: the snowman comes alive and its face, scarf and arms appear.
        if men.count >= 24 { men.removeFirst() }
        let m = Snowman(x: target.x, y: target.y, R: target.parts[0], build: 0.75)
        m.r2 = target.parts[1]
        m.r3 = target.parts[2]
        m.surface = target.surface
        m.offset = target.offset
        men.append(m)
        lumps.removeAll { $0 === target }
    }

    func dropCarried() {
        guard let l = carried else { return }
        carried = nil
        l.surface = nil
        l.rolling = false
        l.vx = 0
        l.vy = 0
        l.state = .falling
    }

    @discardableResult
    func addSnowman(on s: Surface, x: Float, R: Float, build: Float = 0) -> Snowman? {
        if men.count >= 24 { men.removeFirst() }
        let m = Snowman(x: x, y: s.top(at: x), R: R, build: build)
        m.surface = s
        m.offset = x - s.x
        men.append(m)
        return m
    }

    private func destroy(_ m: Snowman) {
        for (c, r) in m.parts() { burst(x: c.x, y: c.y, count: Int(r * 1.3), speed: 360, deposit: 1.6) }
        Sound.shared.play(.thud, gain: 0.5)
        men.removeAll { $0 === m }
    }

    private func updateLumps(_ f: FrameInfo) {
        let dt = f.dt
        for l in lumps {
            l.squashV += (-l.squash * 170 - l.squashV * 11) * dt
            l.squash += l.squashV * dt
            switch l.state {
            case .carried:
                break
            case .falling:
                l.vy += 1400 * dt
                let y0 = l.y
                l.x += l.vx * dt
                l.y += l.vy * dt
                let r = l.parts[0]
                if l.x < r { l.x = r; l.vx = abs(l.vx) * 0.5 }
                if l.x > size.x - r { l.x = size.x - r; l.vx = -abs(l.vx) * 0.5 }
                if l.vy > 0, let s = landing(x: l.x, from: y0, to: l.y) {
                    l.surface = s
                    l.offset = l.x - s.x
                    l.state = .idle
                    l.squashV += min(7, l.vy * 0.006)
                    Sound.shared.play(.thud, gain: min(0.4, l.vy * 0.0004))
                } else if l.y > size.y + 200 {
                    l.x = clampf(l.x, r, size.x - r)
                    l.y = ground.top(at: l.x)
                    l.vy = 0
                    l.surface = ground
                    l.offset = l.x
                    l.state = .idle
                }
            case .idle:
                guard let s = l.surface else { l.state = .falling; continue }
                if !s.alive || l.offset < -2 || l.offset > s.width + 2 {
                    l.surface = nil
                    l.vx = rnd(-30, 30)
                    l.vy = 0
                    l.state = .falling
                    continue
                }
                if s.active {
                    l.x = s.x + l.offset
                    l.y += (s.top(at: l.x) + 3 - l.y) * min(1, dt * 18)
                }
            }
        }
    }

    private func updateMen(_ f: FrameInfo) {
        let dt = f.dt
        for m in men {
            if m.build < 1 {
                m.build = min(1, m.build + dt / 0.9)
            } else if !m.finished {
                m.finished = true
                Sound.shared.play(.chime, gain: 0.3)
            }
            m.tiltV += (-m.tilt * 90 - m.tiltV * 7) * dt
            m.tilt += m.tiltV * dt
            m.squashV += (-m.squash * 170 - m.squashV * 11) * dt
            m.squash += m.squashV * dt
            m.blink -= dt
            if m.blink < -0.13 { m.blink = rnd(2, 7) }

            switch m.state {
            case .held:
                break
            case .falling:
                m.vy += 1400 * dt
                let y0 = m.y
                m.x += m.vx * dt
                m.y += m.vy * dt
                if m.x < m.R { m.x = m.R; m.vx = abs(m.vx) * 0.5 }
                if m.x > size.x - m.R { m.x = size.x - m.R; m.vx = -abs(m.vx) * 0.5 }
                if m.vy > 0, let s = landing(x: m.x, from: y0, to: m.y) {
                    m.surface = s
                    m.offset = m.x - s.x
                    m.state = .idle
                    m.squashV += min(8, m.vy * 0.007)
                    m.tiltV += clampf(m.vx * 0.006, -6, 6)
                    Sound.shared.play(.thud, gain: min(0.5, m.vy * 0.0005))
                } else if m.y > size.y + m.height + 40 {
                    m.y = size.y
                    m.x = clampf(m.x, m.R, size.x - m.R)
                    m.vy = 0
                    m.surface = ground
                    m.offset = m.x
                    m.state = .idle
                }
            case .idle:
                guard let s = m.surface else { m.state = .falling; continue }
                if !s.alive || m.offset < -2 || m.offset > s.width + 2 {
                    m.surface = nil
                    m.vy = 0
                    m.vx = rnd(-30, 30)
                    m.state = .falling
                    continue
                }
                if s.active {
                    m.x = s.x + m.offset
                    m.y += (s.top(at: m.x) + 3 - m.y) * min(1, dt * 18)
                }
            }
        }
    }

    private func updateBalls(_ f: FrameInfo) {
        let dt = f.dt
        var i = 0
        while i < balls.count {
            var b = balls[i]
            var remove = false
            b.age += dt
            if b.glass {
                if b.age > 0.14 {
                    addSplat(b.pos.x, b.pos.y, size: b.r * 8)
                    Sound.shared.play(.thud, gain: 0.45)
                    remove = true
                }
            } else {
                let y0 = b.pos.y
                b.vel.y += 1000 * dt
                b.pos += b.vel * dt
                if let m = men.first(where: { $0.finished && $0.state != .held && $0.hit(point: b.pos) }) {
                    m.tiltV += (b.vel.x >= 0 ? 1 : -1) * 3.6
                    m.squashV += 3
                    m.hp -= 1
                    Sound.shared.play(.thud, gain: 0.45)
                    burst(x: b.pos.x, y: b.pos.y, count: 12, speed: 240, deposit: 0)
                    if m.hp <= 0 { destroy(m) }
                    remove = true
                } else if b.vel.y > 0, let s = landing(x: b.pos.x, from: y0, to: b.pos.y) {
                    burst(x: b.pos.x, y: s.top(at: b.pos.x), count: Int(b.r * 1.6), speed: 240, deposit: 1.2)
                    Sound.shared.play(.thud, gain: 0.3)
                    remove = true
                } else if let r = rects.first(where: { $0.contains(b.pos.x, b.pos.y) }) {
                    let same = b.ignore.map { $0.x == r.x && $0.y == r.y && $0.w == r.w && $0.h == r.h } ?? false
                    if !same {
                        addSplat(b.pos.x, b.pos.y, size: b.r * 7)
                        Sound.shared.play(.thud, gain: 0.35)
                        remove = true
                    }
                } else if b.pos.x < -60 || b.pos.x > size.x + 60 || b.pos.y > size.y + 60 {
                    remove = true
                }
            }
            if remove {
                balls.swapAt(i, balls.count - 1)
                balls.removeLast()
            } else {
                balls[i] = b
                i += 1
            }
        }
    }

    func updatePlay(_ f: FrameInfo) {
        if var h = held {
            h.r = min(22, h.r + f.dt * 16)
            h.pos = pointer
            held = h
        }
        updateLumps(f)
        updateMen(f)
        updateBalls(f)
    }

    // MARK: Drawing

    func fillPlay(_ k: Sink) {
        for m in men where m.surface?.active ?? true { draw(m, k) }
        if let l = carried, let target = stackTarget(for: l), let top = target.centers().last {
            let d = top.1 * 3
            k.put(.glow, top.0.x, top.0.y, d, d, z: zFront, c: SIMD4(warmGold.x * 0.7, warmGold.y * 0.7, warmGold.z * 0.7, 0.35))
        }
        for l in lumps where l.state != .idle || (l.surface?.active ?? true) { draw(l, k) }
        if let h = held { k.put(.body, h.pos.x, h.pos.y, h.r * 2, h.r * 2, z: zFront) }
        for b in balls {
            let d = b.r * 2 * (b.glass ? 1 + b.age * 16 : 1)
            k.put(.body, b.pos.x, b.pos.y, d, d, z: zFront)
        }
    }

    private func draw(_ l: Lump, _ k: Sink) {
        let z: Float = l.state == .idle ? (l.surface?.z ?? zFront) - 0.0001 : zFront
        let sx = 1 + l.squash * 0.5, sy = 1 - l.squash
        for part in l.centers() {
            let d = part.1 * 2
            k.put(.body, part.0.x, part.0.y, d * sx, d * sy, z: z)
        }
    }

    private func draw(_ m: Snowman, _ k: Sink) {
        let z: Float = m.state == .idle ? (m.surface?.z ?? zFront) - 0.0001 : zFront
        let R = m.R, r2 = m.r2, r3 = m.r3, y1 = m.y1, y2 = m.y2, y3 = m.y3
        let cs = cos(m.tilt), sn = sin(m.tilt)
        let sx = 1 + m.squash * 0.5, sy = 1 - m.squash
        let baseX = m.x, baseY = m.y, tilt = m.tilt

        func part(_ s: Sprite, _ lx: Float, _ ly: Float, _ w: Float, _ h: Float, rot: Float = 0, c: SIMD4<Float> = SIMD4(repeating: 1)) {
            let wx = lx * sx, wy = ly * sy
            k.put(s, baseX + wx * cs - wy * sn, baseY + wx * sn + wy * cs, w * sx, h * sy, rot: rot + tilt, z: z, c: c)
        }
        func stage(_ a: Float) -> Float { clampf((m.build - a) / 0.25, 0, 1) }
        func drop(_ a: Float) -> Float { -(1 - easeOutBack(stage(a))) * 200 }

        let e1 = stage(0), e2 = stage(0.25), e3 = stage(0.5), e4 = easeOutBack(stage(0.75))
        let dx = clampf((pointer.x - m.x) * 0.02, -1, 1) * r3 * 0.08
        let dir: Float = pointer.x >= m.x ? 1 : -1

        if e4 > 0.01 {
            let len = R * 1.05
            let left = Float.pi + 0.35, right: Float = -0.35
            part(.arm, -r2 * 0.75 + cos(left) * len / 2 * e4, y2 + sin(left) * len / 2 * e4, len * e4, len * 0.33 * e4, rot: left)
            part(.arm, r2 * 0.75 + cos(right) * len / 2 * e4, y2 + sin(right) * len / 2 * e4, len * e4, len * 0.33 * e4, rot: right)
        }
        if e1 > 0 { part(.body, 0, y1 + drop(0), R * 2, R * 2) }
        if e2 > 0 { part(.body, 0, y2 + drop(0.25), r2 * 2, r2 * 2) }
        if e3 > 0 { part(.body, 0, y3 + drop(0.5), r3 * 2, r3 * 2) }
        if e4 > 0.01 {
            let red = SIMD4<Float>(0.76, 0.14, 0.17, 1)
            let b = R * 0.1 * e4
            part(.button, 0, y2 + r2 * 0.25, b, b)
            part(.button, 0, y1 - R * 0.3, b, b)
            part(.scarf, 0, y2 - r2 * 0.74, r2 * 1.5 * e4, r2 * 0.36 * e4, c: red)
            part(.scarf, r2 * 0.32, y2 - r2 * 0.36, r2 * 0.85 * e4, r2 * 0.27 * e4, rot: 1.4, c: red)
            let closing = m.blink < 0
            let eye = r3 * 0.2 * e4
            part(.eye, -r3 * 0.34 + dx, y3 - r3 * 0.18, eye, closing ? r3 * 0.03 : eye)
            part(.eye, r3 * 0.34 + dx, y3 - r3 * 0.18, eye, closing ? r3 * 0.03 : eye)
            let nose = r3 * 0.85 * e4
            part(.carrot, dir * nose * 0.42 + dx * 2, y3 + r3 * 0.12, dir * nose, r3 * 0.26 * e4)
            let H = r3 * 1.85 * e4
            part(.hat, 0, y3 - r3 * 0.62 - 0.28 * H, H, H)
        }
    }
}
