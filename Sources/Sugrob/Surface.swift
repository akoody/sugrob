import Foundation
import CoreGraphics

/// A one-dimensional snow bank sitting on a horizontal edge: the ground or a window.
final class Surface {
    enum Kind { case ground, window }
    static let cw: Float = 2

    let kind: Kind
    var x: Float
    var y: Float
    private(set) var cols: Int
    var h: [Float]
    var cap: [Float]
    /// Heights after a soft blur. This is what is drawn and landed on.
    var soft: [Float]
    /// The level each column returns to after a dent. Falling snow raises it, a dent does not lower it.
    var rest: [Float]
    private(set) var healing = false
    private var healDelay: Float = 0
    private var healLeft: Float = 0
    private var scratch: [Float] = []
    var order = 0
    var z: Float = 0.9
    var active = true
    var alive = true
    var dirty = true
    var maxH: Float = 0
    let seed = rnd(0, 1000)
    var capHeight: Float
    /// Drives the slow creep of the crest line. Set once per frame.
    var time: Float = 0
    /// Horizontal range of the Dock on a ground surface. Snow dips into a shallow valley there.
    var valley: ClosedRange<Float>?

    var width: Float { Float(cols - 1) * Surface.cw }

    init(kind: Kind, x: Float, y: Float, width: Float, capHeight: Float) {
        self.kind = kind
        self.x = x
        self.y = y
        self.capHeight = capHeight
        cols = max(2, Int(width / Surface.cw) + 1)
        h = Array(repeating: 0, count: cols)
        cap = Array(repeating: 0, count: cols)
        soft = Array(repeating: 0, count: cols)
        rest = Array(repeating: 0, count: cols)
        rebuildShape()
    }

    func rebuildShape() {
        let n = Float(cols - 1)
        for i in 0..<cols {
            let fi = Float(i)
            let wave = sin(fi * 0.013 + seed) * 0.6 + sin(fi * 0.034 + seed * 1.7) * 0.4
            switch kind {
            case .ground:
                let side = pow(abs(2 * fi / n - 1), 1.4)
                var height = capHeight * (0.55 + 0.45 * side) * (1 + 0.14 * wave)
                if let v = valley {
                    let px = fi * Surface.cw
                    height *= 0.12 + 0.88 * smooth(-30, 90, max(v.lowerBound - px, px - v.upperBound))
                }
                cap[i] = height
            case .window:
                let edge = min(fi, n - fi) * Surface.cw
                cap[i] = capHeight * pow(min(1, edge / 16), 0.7) * (0.88 + 0.12 * wave)
            }
        }
        // The shape itself never exceeds the slope snow can hold, so a full drift is already at rest
        // and does not spend half a minute slumping into place.
        let step: Float = 0.74
        for i in 1..<cols { cap[i] = min(cap[i], cap[i - 1] + step) }
        for i in stride(from: cols - 2, through: 0, by: -1) { cap[i] = min(cap[i], cap[i + 1] + step) }
        for i in 0..<cols {
            h[i] = min(h[i], cap[i])
            rest[i] = min(rest[i], cap[i])
        }
        dirty = true
    }

    /// Call after snow is pushed aside but not gone, so the drift closes over the gap by itself.
    func noteDent() {
        healing = true
        healDelay = 1.2
        healLeft = 28
    }

    /// Snow appears on a new surface gradually, up to the given share of its cap.
    func growIn(_ share: Float) {
        for i in 0..<cols { rest[i] = cap[i] * share }
        noteDent()
    }

    /// Call after snow has really left this surface, so it does not come back.
    func settle() {
        rest = h
        healing = false
    }

    func heal(dt: Float) {
        guard healing else { return }
        if healDelay > 0 {
            healDelay -= dt
            return
        }
        healLeft -= dt
        var open = false
        for i in 0..<cols {
            let gap = rest[i] - h[i]
            if gap > 0.03 {
                h[i] += min(gap, gap * dt * 0.28 + dt * 0.5)
                open = true
            }
        }
        dirty = true
        if !open || healLeft <= 0 { settle() }
    }

    func prewarm(_ low: Float, _ high: Float) {
        let f = rnd(low, high)
        for i in 0..<cols { h[i] = cap[i] * f }
        dirty = true
        relax()
        settle()
    }

    func resize(width: Float) {
        let newCols = max(2, Int(width / Surface.cw) + 1)
        guard newCols != cols else { return }
        var resampled = [Float](repeating: 0, count: newCols)
        let ratio = Float(cols - 1) / Float(newCols - 1)
        var resampledRest = resampled
        for i in 0..<newCols {
            let j = min(cols - 1, Int(Float(i) * ratio))
            resampled[i] = h[j]
            resampledRest[i] = rest[j]
        }
        rest = resampledRest
        cols = newCols
        h = resampled
        cap = Array(repeating: 0, count: newCols)
        soft = Array(repeating: 0, count: newCols)
        rebuildShape()
        relax()
    }

    @inline(__always) func column(_ wx: Float) -> Int { clampInt(Int((wx - x) / Surface.cw), 0, cols - 1) }
    @inline(__always) func height(at wx: Float) -> Float { h[column(wx)] }
    @inline(__always) func top(at wx: Float) -> Float { y - visual(column(wx)) }

    /// The drawn height: resting snow plus a slow swell that travels along the crest.
    @inline(__always) func visual(_ i: Int) -> Float {
        let j = clampInt(i, 0, cols - 1)
        let x = Float(j) * Surface.cw + seed * 3
        let amp: Float = kind == .ground ? 0.08 : 0.05
        return soft[j] * (1 + amp * sin(x * 0.018 - time * 0.24) + amp * 0.6 * sin(x * 0.047 + time * 0.33))
    }

    /// A second ridge behind the first, drifting the other way.
    @inline(__always) func backVisual(_ i: Int) -> Float {
        let j = clampInt(i, 0, cols - 1)
        let x = Float(j) * Surface.cw + seed * 5
        return soft[j] * (1.12 + 0.17 * sin(x * 0.011 + time * 0.15) + 0.08 * sin(x * 0.031 - time * 0.21)) + min(soft[j], 3)
    }

    func deposit(at wx: Float, amount: Float) {
        let c = column(wx)
        for i in max(0, c - 7)...min(cols - 1, c + 7) {
            h[i] = min(cap[i], h[i] + amount * Float(8 - abs(i - c)) / 64)
            rest[i] = max(rest[i], h[i])
        }
        dirty = true
    }

    func relax() {
        guard dirty else { return }
        let limit: Float = 0.8
        var moved = false
        var peak: Float = 0
        let n = cols
        h.withUnsafeMutableBufferPointer { p in
            for _ in 0..<2 {
                for i in 0..<(n - 1) {
                    let d = p[i] - p[i + 1]
                    if abs(d) > limit + 0.03 {
                        let t = (abs(d) - limit) * 0.3 * (d > 0 ? 1 : -1)
                        p[i] -= t
                        p[i + 1] += t
                        moved = true
                    }
                }
            }
            for i in 0..<n {
                if p[i] > cap[i] { p[i] = cap[i] }
                if p[i] > peak { peak = p[i] }
            }
        }
        maxH = peak
        dirty = moved
        blur()
    }

    private func blur() {
        let radius = 8
        let window = Float(radius * 2 + 1)
        if scratch.count != cols { scratch = Array(repeating: 0, count: cols) }
        let n = cols
        h.withUnsafeBufferPointer { h in
            scratch.withUnsafeMutableBufferPointer { first in
                soft.withUnsafeMutableBufferPointer { out in
                    var sum: Float = 0
                    for i in -radius...radius { sum += h[clampInt(i, 0, n - 1)] }
                    for i in 0..<n {
                        first[i] = sum / window
                        sum += h[clampInt(i + radius + 1, 0, n - 1)] - h[clampInt(i - radius, 0, n - 1)]
                    }
                    sum = 0
                    for i in -radius...radius { sum += first[clampInt(i, 0, n - 1)] }
                    for i in 0..<n {
                        out[i] = sum / window
                        sum += first[clampInt(i + radius + 1, 0, n - 1)] - first[clampInt(i - radius, 0, n - 1)]
                    }
                }
            }
        }
        for i in 0..<cols where soft[i] > cap[i] { soft[i] = cap[i] }
    }
}

@inline(__always) func clampInt(_ v: Int, _ a: Int, _ b: Int) -> Int { min(max(v, a), b) }
