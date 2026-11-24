import CoreAudio
import Synchronization

/// What the IOProc shares with the actor. One per tapped process, heap-allocated, never moved.
///
/// The IOProc runs on Core Audio's real-time thread, so everything here is a lock-free atomic with
/// relaxed ordering: each field is an independent value, and a stale read costs at most one buffer.
struct RenderState: ~Copyable {
    /// The gain the actor wants, as `Float.bitPattern`. Written by the actor, read by the IOProc.
    let targetGain = Atomic<UInt32>(Float(1).bitPattern)
    /// The gain the last buffer ended on. Only the IOProc touches it; it ramps toward `targetGain`.
    let currentGain = Atomic<UInt32>(Float(1).bitPattern)
    /// `false` while probing: the tap is unmuted and the IOProc writes silence, so the app plays as normal.
    /// `true` once the tap mutes the app: the IOProc writes the tap's input × gain.
    let isActive = Atomic<Bool>(false)
    /// Set by the IOProc the first time the tap delivers a non-zero sample. Without audio-capture
    /// consent the tap delivers exact zeros, so this is the permission signal.
    let heardSignal = Atomic<Bool>(false)
    /// IO cycles run. Diagnostics and the probe's "has the device started" check.
    let cycles = Atomic<UInt64>(0)
}

/// The real-time part of per-app volume: gain applied from the tap's buffers into the output device's.
///
/// Pure over `AudioBufferList`s, so it's testable with fixtures. Nothing in here allocates, locks,
/// logs, or touches Swift concurrency.
enum GainKernel {
    /// Where an output channel's samples come from.
    enum Source: Equatable {
        case channel(Int)
        /// The average of two input channels (a stereo tap into a mono output).
        case mix(Int, Int)
        case silence
    }

    /// A channel inside an `AudioBufferList`: its first sample, the distance between frames, and the frame count.
    struct Channel {
        let base: UnsafeMutablePointer<Float>
        let stride: Int
        let frames: Int
    }

    /// The Core Audio IOProc. `clientData` is the tap's `UnsafeMutablePointer<RenderState>`.
    static let ioProc: AudioDeviceIOProc = { _, _, input, _, output, _, clientData in
        guard let clientData else {
            return noErr
        }
        process(state: clientData.assumingMemoryBound(to: RenderState.self), input: input, output: output)
        return noErr
    }

    /// Volume in 0...1 as a gain. NaN counts as untouched (1); ±infinity clamps like any other value.
    static func gain(for volume: Double) -> Float {
        guard !volume.isNaN else {
            return 1
        }
        return Float(min(1, max(0, volume)))
    }

    /// One IO cycle.
    static func process(
        state: UnsafeMutablePointer<RenderState>,
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>
    ) {
        state.pointee.cycles.wrappingAdd(1, ordering: .relaxed)
        if !state.pointee.heardSignal.load(ordering: .relaxed), hasSignal(input) {
            state.pointee.heardSignal.store(true, ordering: .relaxed)
        }
        guard state.pointee.isActive.load(ordering: .relaxed) else {
            silence(output)
            return
        }
        let target = Float(bitPattern: state.pointee.targetGain.load(ordering: .relaxed))
        let current = Float(bitPattern: state.pointee.currentGain.load(ordering: .relaxed))
        render(input: input, output: output, from: current, to: target)
        state.pointee.currentGain.store(target.bitPattern, ordering: .relaxed)
    }

    /// Writes `input × gain` into `output`, ramping linearly from `start` to `end` across the buffer so a
    /// slider move doesn't click. Handles interleaved and deinterleaved Float32 on either side, and maps
    /// channels with `source(forOutput:outputChannels:inputChannels:)`. Every output sample is written.
    static func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        from start: Float,
        to end: Float
    ) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)
        let inputChannels = channelCount(inList)
        let outputChannels = channelCount(outList)
        for index in 0 ..< outputChannels {
            guard let out = channel(index, in: outList) else {
                continue
            }
            switch source(forOutput: index, outputChannels: outputChannels, inputChannels: inputChannels) {
            case let .channel(sourceIndex):
                guard let source = channel(sourceIndex, in: inList) else {
                    fill(out, from: 0)
                    continue
                }
                copy(source, nil, into: out, from: start, to: end)
            case let .mix(first, second):
                guard let first = channel(first, in: inList), let second = channel(second, in: inList) else {
                    fill(out, from: 0)
                    continue
                }
                copy(first, second, into: out, from: start, to: end)
            case .silence:
                fill(out, from: 0)
            }
        }
    }

    /// Stereo mixdown taps feed stereo, mono, and multichannel outputs: mono gets L+R averaged,
    /// a mono source is duplicated to the first two outputs, and channels past the source's are silent.
    static func source(forOutput channel: Int, outputChannels: Int, inputChannels: Int) -> Source {
        guard inputChannels > 0, channel >= 0, channel < outputChannels else {
            return .silence
        }
        if outputChannels == 1 {
            return inputChannels >= 2 ? .mix(0, 1) : .channel(0)
        }
        if inputChannels == 1 {
            return channel < 2 ? .channel(0) : .silence
        }
        return channel < inputChannels ? .channel(channel) : .silence
    }

    /// Whether any sample in the list is non-zero.
    static func hasSignal(_ list: UnsafePointer<AudioBufferList>) -> Bool {
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list)) {
            guard let data = buffer.mData else {
                continue
            }
            let samples = UnsafeBufferPointer(
                start: data.assumingMemoryBound(to: Float.self),
                count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            )
            for sample in samples where sample != 0 {
                return true
            }
        }
        return false
    }

    /// Zeros every buffer in the list.
    static func silence(_ list: UnsafeMutablePointer<AudioBufferList>) {
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            if let data = buffer.mData {
                data.initializeMemory(as: UInt8.self, repeating: 0, count: Int(buffer.mDataByteSize))
            }
        }
    }

    static func channelCount(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
        var count = 0
        for buffer in list {
            count += Int(buffer.mNumberChannels)
        }
        return count
    }

    /// The `index`th channel across all buffers, counting each buffer's interleaved channels in order.
    static func channel(_ index: Int, in list: UnsafeMutableAudioBufferListPointer) -> Channel? {
        var remaining = index
        for buffer in list {
            let channels = Int(buffer.mNumberChannels)
            if remaining < channels {
                guard let data = buffer.mData else {
                    return nil
                }
                let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                return Channel(base: data.assumingMemoryBound(to: Float.self) + remaining, stride: channels, frames: frames)
            }
            remaining -= channels
        }
        return nil
    }

    private static func copy(_ first: Channel, _ second: Channel?, into out: Channel, from start: Float, to end: Float) {
        // Two-argument `min` only: the variadic overload builds an array, and this runs on the IO thread.
        let frames = min(min(out.frames, first.frames), second?.frames ?? Int.max)
        let step = frames > 0 ? (end - start) / Float(frames) : 0
        let scale: Float = second == nil ? 1 : 0.5
        for frame in 0 ..< frames {
            let gain = step == 0 ? end : start + step * Float(frame + 1)
            var sample = first.base[frame * first.stride]
            if let second {
                sample += second.base[frame * second.stride]
            }
            out.base[frame * out.stride] = sample * scale * gain
        }
        fill(out, from: frames)
    }

    private static func fill(_ out: Channel, from frame: Int) {
        guard frame < out.frames else {
            return
        }
        for index in frame ..< out.frames {
            out.base[index * out.stride] = 0
        }
    }
}
