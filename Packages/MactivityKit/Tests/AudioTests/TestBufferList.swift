import CoreAudio
import Foundation

/// An `AudioBufferList` of Float32 buffers the test owns. `channelsPerBuffer` is the layout:
/// `[2]` is interleaved stereo, `[1, 1]` deinterleaved stereo, `[1]` mono.
final class TestBufferList {
    let list: UnsafeMutableAudioBufferListPointer
    let layout: [Int]
    let frames: Int
    private let storage: [UnsafeMutablePointer<Float>]

    init(channelsPerBuffer layout: [Int], frames: Int, fill: Float = 0) {
        self.layout = layout
        self.frames = frames
        list = AudioBufferList.allocate(maximumBuffers: max(1, layout.count))
        list.count = layout.count
        storage = layout.map { channels in
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: max(1, channels * frames))
            samples.initialize(repeating: fill, count: max(1, channels * frames))
            return samples
        }
        for (index, channels) in layout.enumerated() {
            list[index] = AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(channels * frames * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(storage[index])
            )
        }
    }

    deinit {
        for samples in storage {
            samples.deallocate()
        }
        free(list.unsafeMutablePointer)
    }

    var pointer: UnsafeMutablePointer<AudioBufferList> {
        list.unsafeMutablePointer
    }

    var channelCount: Int {
        layout.reduce(0, +)
    }

    func set(channel: Int, to samples: [Float]) {
        let (buffer, offset, stride) = locate(channel)
        for (frame, sample) in samples.prefix(frames).enumerated() {
            storage[buffer][frame * stride + offset] = sample
        }
    }

    func samples(channel: Int) -> [Float] {
        let (buffer, offset, stride) = locate(channel)
        return (0 ..< frames).map { storage[buffer][$0 * stride + offset] }
    }

    private func locate(_ channel: Int) -> (buffer: Int, offset: Int, stride: Int) {
        var remaining = channel
        for (index, channels) in layout.enumerated() {
            if remaining < channels {
                return (index, remaining, channels)
            }
            remaining -= channels
        }
        preconditionFailure("channel \(channel) out of range for layout \(layout)")
    }
}
