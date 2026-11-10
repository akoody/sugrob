import AVFoundation

/// All sounds are synthesized once at first use and played through AVAudioPlayer.
/// A silent Sugrob keeps no audio session or engine running, and a missing output
/// device simply means no sound rather than a crash.
final class Sound {
    enum Kind: CaseIterable { case thud, whoosh, crunch, pop, chime }

    static let shared = Sound()

    private let sampleRate = 44100.0
    private var players: [Kind: [AVAudioPlayer]] = [:]
    private var nextIndex: [Kind: Int] = [:]
    private var lastPlayed: [Kind: CFTimeInterval] = [:]
    private var ready = false
    var muted = false

    private func prepare() {
        guard !ready else { return }
        ready = true
        for k in Kind.allCases {
            let data = synthesize(k)
            players[k] = (0..<3).compactMap { _ in try? AVAudioPlayer(data: data) }
        }
    }

    func play(_ kind: Kind, gain: Float, minGap: CFTimeInterval = 0.03) {
        guard !muted, gain > 0.01 else { return }
        let now = CACurrentMediaTime()
        if let last = lastPlayed[kind], now - last < minGap { return }
        lastPlayed[kind] = now
        prepare()
        guard let pool = players[kind], !pool.isEmpty else { return }
        let i = nextIndex[kind, default: 0]
        nextIndex[kind] = (i + 1) % pool.count
        pool[i].currentTime = 0
        pool[i].volume = min(1, gain)
        pool[i].play()
    }

    /// Every sound must decode, or it would silently never play.
    func allSoundsDecode() -> Bool {
        prepare()
        return Kind.allCases.allSatisfy { k in players[k]?.count == 3 && (players[k]?.first?.duration ?? 0) > 0.05 }
    }

    // MARK: Synthesis

    private func buffer(seconds: Double, _ fill: (Int, Double, UnsafeMutablePointer<Float>) -> Void) -> Data {
        let frames = Int(seconds * sampleRate)
        var samples = [Float](repeating: 0, count: frames)
        samples.withUnsafeMutableBufferPointer { fill(frames, sampleRate, $0.baseAddress!) }
        return wav(samples)
    }

    private func wav(_ samples: [Float]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate) * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        for v in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, v)) * 32767))) }
        return d
    }

    private func synthesize(_ k: Kind) -> Data {
        var rng = SeededRandom(UInt64(abs(String(describing: k).hashValue % 9999) + 1))
        switch k {
        case .thud:
            return buffer(seconds: 0.28) { n, sr, out in
                var lp = 0.0
                for i in 0..<n {
                    let t = Double(i) / sr
                    let f = 60 + 90 * exp(-t * 26)
                    let tone = sin(2 * .pi * f * t) * exp(-t * 17)
                    lp += (rng.range(-1, 1) - lp) * 0.2
                    out[i] = Float(tone * 0.8 + lp * exp(-t * 32) * 1.4)
                }
            }
        case .whoosh:
            return buffer(seconds: 0.3) { n, sr, out in
                var lp = 0.0
                for i in 0..<n {
                    let p = Double(i) / Double(n)
                    lp += (rng.range(-1, 1) - lp) * (0.05 + 0.35 * sin(.pi * p))
                    out[i] = Float(lp * sin(.pi * p) * 1.1)
                }
            }
        case .crunch:
            return buffer(seconds: 0.18) { n, sr, out in
                var grain = 0.0
                for i in 0..<n {
                    if rng.next() < 0.012 { grain = rng.range(0.4, 1) }
                    grain *= 0.992
                    out[i] = Float(rng.range(-1, 1) * grain * 0.55)
                }
            }
        case .pop:
            return buffer(seconds: 0.09) { n, sr, out in
                for i in 0..<n {
                    let t = Double(i) / sr
                    let frequency: Double = 760.0 - 2600.0 * t
                    let phase: Double = 2.0 * Double.pi * frequency * t
                    let envelope: Double = exp(-t * 46.0)
                    out[i] = Float(sin(phase) * envelope * 0.7)
                }
            }
        case .chime:
            let notes: [(Double, Double)] = [(1046.5, 0), (1318.5, 0.08), (1568, 0.16), (2093, 0.24)]
            return buffer(seconds: 1.1) { n, sr, out in
                for i in 0..<n {
                    let t = Double(i) / sr
                    var v = 0.0
                    for (f, at) in notes where t >= at {
                        let u = t - at
                        v += (sin(2 * .pi * f * u) + 0.3 * sin(2 * .pi * f * 2.76 * u)) * exp(-u * 5.5)
                    }
                    out[i] = Float(v * 0.17)
                }
            }
        }
    }
}
