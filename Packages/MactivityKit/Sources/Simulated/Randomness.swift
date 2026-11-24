import Foundation

/// SplitMix64. Deterministic for a given seed, so simulated runs and tests are repeatable.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A smooth, repeatable wander in 0...1: a few incommensurate sines with seeded phases, plus
/// rare short spikes. Believable enough for a CPU line; cheap enough to call every tick.
struct Wander: Sendable {
    private let phases: [Double]
    private let spikeSeed: UInt64
    /// Where the wander sits on average, 0...1.
    let base: Double
    /// Half the peak-to-peak range of the smooth part.
    let amplitude: Double
    /// Probability that a given tick starts a spike.
    let spikeChance: Double

    init(seed: UInt64, base: Double, amplitude: Double, spikeChance: Double = 0.02) {
        var generator = SeededGenerator(seed: seed)
        phases = (0 ..< 3).map { _ in Double.random(in: 0 ..< 2 * .pi, using: &generator) }
        spikeSeed = generator.next()
        self.base = base
        self.amplitude = amplitude
        self.spikeChance = spikeChance
    }

    /// The value at tick `tick`. Pure: the same tick always gives the same value.
    func value(at tick: Int) -> Double {
        let t = Double(tick)
        let smooth = 0.5 * sin(t / 9 + phases[0]) + 0.3 * sin(t / 23 + phases[1]) + 0.2 * sin(t / 61 + phases[2])
        var value = base + amplitude * smooth
        // A spike lasts four ticks and decays.
        for age in 0 ..< 4 where tick - age >= 0 && startsSpike(at: tick - age) {
            value += 0.45 * pow(0.55, Double(age))
        }
        return min(1, max(0, value))
    }

    private func startsSpike(at tick: Int) -> Bool {
        var generator = SeededGenerator(seed: spikeSeed ^ UInt64(truncatingIfNeeded: tick) &* 0x2545_F491_4F6C_DD1D)
        return Double.random(in: 0 ..< 1, using: &generator) < spikeChance
    }
}
