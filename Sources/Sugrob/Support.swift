import Foundation
import simd

typealias V2 = SIMD2<Float>

let appVersion = "3.2.1"

/// Interface language follows the system: Russian if it is preferred, English otherwise.
let isRussian = Locale.preferredLanguages.first?.lowercased().hasPrefix("ru") ?? false
func L(_ ru: String, _ en: String) -> String { isRussian ? ru : en }

// MARK: Random

private var rngState: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000) | 1

@inline(__always) func frand() -> Float {
    rngState ^= rngState << 13
    rngState ^= rngState >> 7
    rngState ^= rngState << 17
    return Float(rngState >> 40) / Float(1 << 24)
}

@inline(__always) func rnd(_ a: Float, _ b: Float) -> Float { a + (b - a) * frand() }

struct SeededRandom {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 2654435761 &+ 88172645463325252 }
    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state >> 11) / Double(1 << 53)
    }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
}

// MARK: Math

@inline(__always) func clampf(_ v: Float, _ a: Float, _ b: Float) -> Float { min(max(v, a), b) }
@inline(__always) func lerpf(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inline(__always) func smooth(_ a: Float, _ b: Float, _ v: Float) -> Float {
    let t = clampf((v - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)
}
func easeOutBack(_ x: Float) -> Float {
    let t = clampf(x, 0, 1)
    let c: Float = 1.70158
    let u = t - 1
    return 1 + (c + 1) * u * u * u + c * u * u
}

struct Rect2 {
    var x: Float, y: Float, w: Float, h: Float
    @inline(__always) func contains(_ px: Float, _ py: Float) -> Bool {
        px >= x && px <= x + w && py >= y && py <= y + h
    }
}

// MARK: Noise (frost baking and drift shapes)

@inline(__always) func hash2(_ x: Int32, _ y: Int32) -> Float {
    var h = UInt32(bitPattern: x &* 374761393 &+ y &* 668265263)
    h = (h ^ (h >> 13)) &* 1274126177
    return Float((h ^ (h >> 16)) & 0xFFFFFF) / Float(0xFFFFFF)
}

func valueNoise(_ x: Float, _ y: Float) -> Float {
    let fx = floor(x), fy = floor(y)
    let ix = Int32(fx), iy = Int32(fy)
    let dx = x - fx, dy = y - fy
    let ux = dx * dx * (3 - 2 * dx), uy = dy * dy * (3 - 2 * dy)
    let a = hash2(ix, iy), b = hash2(ix + 1, iy)
    let c = hash2(ix, iy + 1), d = hash2(ix + 1, iy + 1)
    return lerpf(lerpf(a, b, ux), lerpf(c, d, ux), uy)
}

func ridged(_ x: Float, _ y: Float, octaves: Int) -> Float {
    var sum: Float = 0, amp: Float = 0.5, fx = x, fy = y
    for _ in 0..<octaves {
        let n = 1 - abs(valueNoise(fx, fy) * 2 - 1)
        sum += n * n * amp
        // Rotating each octave removes the axis-aligned grid look of value noise.
        let rx = (fx * 0.8 - fy * 0.6) * 2.13
        fy = (fx * 0.6 + fy * 0.8) * 2.13
        fx = rx
        amp *= 0.5
    }
    return sum
}
