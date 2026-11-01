import AVFoundation

/// Tiny synthesizer for the scale's sounds: the piezo beep, the tactile key click
/// and the soft tap of a file landing on the platform.
final class Sound {
    static let shared = Sound()
    var enabled = true

    private var pools: [String: [AVAudioPlayer]] = [:]
    private var cursor: [String: Int] = [:]
    private let rate = 44_100.0

    private init() {
        register("beep", samples: beep(freq: 2730, duration: 0.085), volume: 0.16)
        register("beepLong", samples: beep(freq: 2730, duration: 0.26), volume: 0.16)
        register("click", samples: click(), volume: 0.5)
        register("release", samples: click(pitch: 1.35, level: 0.45), volume: 0.35)
        register("tap", samples: tap(), volume: 0.6)
        register("lift", samples: whoosh(), volume: 0.18)
    }

    func play(_ name: String, volume: Float? = nil) {
        guard enabled, let pool = pools[name], !pool.isEmpty else { return }
        let i = cursor[name, default: 0]
        cursor[name] = (i + 1) % pool.count
        let p = pool[i]
        if let volume { p.volume = volume }
        p.currentTime = 0
        p.play()
    }

    // MARK: - Synthesis

    private func beep(freq: Double, duration: Double) -> [Float] {
        let n = Int(duration * rate)
        return (0..<n).map { i in
            let t = Double(i) / rate
            let env = min(1, t / 0.003) * min(1, (duration - t) / 0.012)
            // Piezo: strong fundamental with odd harmonics (slightly square)
            let s = sin(2 * .pi * freq * t) + 0.28 * sin(2 * .pi * freq * 3 * t) + 0.1 * sin(2 * .pi * freq * 5 * t)
            return Float(s * env * 0.7)
        }
    }

    private func click(pitch: Double = 1, level: Double = 1) -> [Float] {
        let duration = 0.045
        let n = Int(duration * rate)
        var lp = 0.0
        return (0..<n).map { i in
            let t = Double(i) / rate
            let noise = Double.random(in: -1...1)
            lp += (noise - lp) * 0.35
            let snap = lp * exp(-t / 0.0022) * 1.4
            let body = sin(2 * .pi * 1900 * pitch * t) * exp(-t / 0.004) * 0.5
            let thock = sin(2 * .pi * 240 * pitch * t) * exp(-t / 0.012) * 0.6
            return Float((snap + body + thock) * level)
        }
    }

    private func tap() -> [Float] {
        let duration = 0.09
        let n = Int(duration * rate)
        var lp = 0.0
        return (0..<n).map { i in
            let t = Double(i) / rate
            lp += (Double.random(in: -1...1) - lp) * 0.12
            let thud = sin(2 * .pi * 130 * t) * exp(-t / 0.018)
            let ring = sin(2 * .pi * 3150 * t) * exp(-t / 0.03) * 0.06   // metal plate ring
            return Float(lp * exp(-t / 0.006) * 2.2 + thud * 0.7 + ring)
        }
    }

    private func whoosh() -> [Float] {
        let duration = 0.16
        let n = Int(duration * rate)
        var lp = 0.0
        return (0..<n).map { i in
            let t = Double(i) / rate
            lp += (Double.random(in: -1...1) - lp) * 0.05
            let env = sin(.pi * t / duration)
            return Float(lp * env * 1.6)
        }
    }

    private func register(_ name: String, samples: [Float], volume: Float) {
        let data = wav(samples)
        pools[name] = (0..<3).compactMap { _ in
            let p = try? AVAudioPlayer(data: data)
            p?.volume = volume
            p?.prepareToPlay()
            return p
        }
    }

    private func wav(_ samples: [Float]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let byteCount = UInt32(samples.count * 2)
        d.append("RIFF".data(using: .ascii)!); u32(36 + byteCount)
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(byteCount)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32_000)
            u16(UInt16(bitPattern: v))
        }
        return d
    }
}
