@testable import Audio
import CoreAudio
import Testing

struct GainBufferFixture: Decodable {
    struct Gain: Decodable {
        let volume: Double
        let gain: Float
    }

    let left: [Float]
    let right: [Float]
    let gains: [Gain]
    let expectedMono: [Float]

    var frames: Int {
        left.count
    }

    /// The fixture as a tap's input in the given layout (`[2]` interleaved, `[1, 1]` deinterleaved).
    func input(layout: [Int]) -> TestBufferList {
        let buffers = TestBufferList(channelsPerBuffer: layout, frames: frames)
        buffers.set(channel: 0, to: left)
        if buffers.channelCount > 1 {
            buffers.set(channel: 1, to: right)
        }
        return buffers
    }
}

@Suite("Gain kernel")
struct GainKernelTests {
    let fixture: GainBufferFixture

    init() throws {
        fixture = try Fixtures.load("audio-gain-buffers.json")
    }

    @Test("Volume → gain clamps to 0...1; NaN is untouched")
    func gainClamping() {
        for entry in fixture.gains {
            #expect(GainKernel.gain(for: entry.volume) == entry.gain, "volume \(entry.volume)")
        }
        #expect(GainKernel.gain(for: .nan) == 1)
        #expect(GainKernel.gain(for: .infinity) == 1)
        #expect(GainKernel.gain(for: -.infinity) == 0)
    }

    @Test(
        "Stereo tap → stereo output at every fixture gain, in every buffer layout",
        arguments: [([2], [2]), ([1, 1], [2]), ([2], [1, 1]), ([1, 1], [1, 1])]
    )
    func stereoToStereo(inputLayout: [Int], outputLayout: [Int]) {
        for entry in fixture.gains {
            let input = fixture.input(layout: inputLayout)
            let output = TestBufferList(channelsPerBuffer: outputLayout, frames: fixture.frames, fill: 9)
            GainKernel.render(input: input.pointer, output: output.pointer, from: entry.gain, to: entry.gain)
            #expect(output.samples(channel: 0) == fixture.left.map { $0 * entry.gain }, "gain \(entry.gain)")
            #expect(output.samples(channel: 1) == fixture.right.map { $0 * entry.gain }, "gain \(entry.gain)")
        }
    }

    @Test("Gain 0 writes exact silence; gain 1 is bit-identical")
    func zeroAndUnity() {
        let input = fixture.input(layout: [2])
        let silent = TestBufferList(channelsPerBuffer: [2], frames: fixture.frames, fill: 9)
        GainKernel.render(input: input.pointer, output: silent.pointer, from: 0, to: 0)
        #expect(silent.samples(channel: 0).allSatisfy { $0 == 0 })
        #expect(silent.samples(channel: 1).allSatisfy { $0 == 0 })

        let unity = TestBufferList(channelsPerBuffer: [2], frames: fixture.frames, fill: 9)
        GainKernel.render(input: input.pointer, output: unity.pointer, from: 1, to: 1)
        #expect(unity.samples(channel: 0) == fixture.left)
        #expect(unity.samples(channel: 1) == fixture.right)
    }

    @Test("Stereo tap → mono output averages L and R")
    func stereoToMono() {
        let input = fixture.input(layout: [2])
        let output = TestBufferList(channelsPerBuffer: [1], frames: fixture.frames, fill: 9)
        GainKernel.render(input: input.pointer, output: output.pointer, from: 0.5, to: 0.5)
        #expect(output.samples(channel: 0) == fixture.expectedMono.map { $0 * 0.5 })
    }

    @Test("Mono source → stereo output duplicates it")
    func monoToStereo() {
        let input = fixture.input(layout: [1])
        let output = TestBufferList(channelsPerBuffer: [1, 1], frames: fixture.frames, fill: 9)
        GainKernel.render(input: input.pointer, output: output.pointer, from: 1, to: 1)
        #expect(output.samples(channel: 0) == fixture.left)
        #expect(output.samples(channel: 1) == fixture.left)
    }

    @Test("Stereo tap → four-channel output: channels 3 and 4 are silent")
    func stereoToQuad() {
        let input = fixture.input(layout: [2])
        let output = TestBufferList(channelsPerBuffer: [2, 2], frames: fixture.frames, fill: 9)
        GainKernel.render(input: input.pointer, output: output.pointer, from: 1, to: 1)
        #expect(output.samples(channel: 0) == fixture.left)
        #expect(output.samples(channel: 1) == fixture.right)
        #expect(output.samples(channel: 2).allSatisfy { $0 == 0 })
        #expect(output.samples(channel: 3).allSatisfy { $0 == 0 })
    }

    @Test("Output longer than the input: the tail is zeroed, not left stale")
    func shortInput() {
        let input = fixture.input(layout: [2])
        let output = TestBufferList(channelsPerBuffer: [2], frames: fixture.frames * 2, fill: 9)
        GainKernel.render(input: input.pointer, output: output.pointer, from: 1, to: 1)
        let left = output.samples(channel: 0)
        #expect(Array(left.prefix(fixture.frames)) == fixture.left)
        #expect(left.dropFirst(fixture.frames).allSatisfy { $0 == 0 })
    }

    @Test("No input channels: output is silent")
    func noInput() {
        let input = TestBufferList(channelsPerBuffer: [], frames: fixture.frames)
        let output = TestBufferList(channelsPerBuffer: [2], frames: fixture.frames, fill: 9)
        GainKernel.render(input: input.pointer, output: output.pointer, from: 1, to: 1)
        #expect(output.samples(channel: 0).allSatisfy { $0 == 0 })
    }

    @Test("A gain change ramps across one buffer, ending exactly on the target")
    func ramp() {
        let frames = 4
        let input = TestBufferList(channelsPerBuffer: [2], frames: frames, fill: 1)
        let output = TestBufferList(channelsPerBuffer: [2], frames: frames)
        GainKernel.render(input: input.pointer, output: output.pointer, from: 1, to: 0)
        #expect(output.samples(channel: 0) == [0.75, 0.5, 0.25, 0])
        #expect(output.samples(channel: 1) == [0.75, 0.5, 0.25, 0])
    }

    @Test(
        "Channel mapping",
        arguments: [
            (0, 2, 2, GainKernel.Source.channel(0)),
            (1, 2, 2, .channel(1)),
            (0, 1, 2, .mix(0, 1)),
            (0, 1, 1, .channel(0)),
            (1, 2, 1, .channel(0)),
            (2, 4, 1, .silence),
            (2, 4, 2, .silence),
            (0, 2, 0, .silence),
            (5, 2, 2, .silence),
        ]
    )
    func mapping(output: Int, outputChannels: Int, inputChannels: Int, expected: GainKernel.Source) {
        #expect(GainKernel.source(forOutput: output, outputChannels: outputChannels, inputChannels: inputChannels) == expected)
    }

    @Test("Signal detection: exact zeros are silence, anything else is signal")
    func signal() {
        let silent = TestBufferList(channelsPerBuffer: [1, 1], frames: 8)
        #expect(!GainKernel.hasSignal(silent.pointer))
        silent.set(channel: 1, to: [0, 0, 0, 0, 0, 0, 0, 1e-9])
        #expect(GainKernel.hasSignal(silent.pointer))
    }

    @Test("IO cycle: probing writes silence and notes signal; active applies the target gain")
    func ioCycle() {
        let state = UnsafeMutablePointer<RenderState>.allocate(capacity: 1)
        state.initialize(to: RenderState())
        defer {
            state.deinitialize(count: 1)
            state.deallocate()
        }
        let input = fixture.input(layout: [2])
        let output = TestBufferList(channelsPerBuffer: [2], frames: fixture.frames, fill: 9)

        GainKernel.process(state: state, input: input.pointer, output: output.pointer)
        #expect(output.samples(channel: 0).allSatisfy { $0 == 0 })
        let heard = state.pointee.heardSignal.load(ordering: .relaxed)
        let cyclesAfterProbe = state.pointee.cycles.load(ordering: .relaxed)
        #expect(heard)
        #expect(cyclesAfterProbe == 1)

        state.pointee.isActive.store(true, ordering: .relaxed)
        state.pointee.targetGain.store(Float(0.5).bitPattern, ordering: .relaxed)
        state.pointee.currentGain.store(Float(0.5).bitPattern, ordering: .relaxed)
        GainKernel.process(state: state, input: input.pointer, output: output.pointer)
        #expect(output.samples(channel: 0) == fixture.left.map { $0 * 0.5 })
        #expect(output.samples(channel: 1) == fixture.right.map { $0 * 0.5 })
        let cyclesAfterActive = state.pointee.cycles.load(ordering: .relaxed)
        #expect(cyclesAfterActive == 2)
    }

    @Test("The IOProc entry point with no client data is a no-op")
    func ioProcWithoutState() {
        let input = fixture.input(layout: [2])
        let output = TestBufferList(channelsPerBuffer: [2], frames: fixture.frames, fill: 9)
        var time = AudioTimeStamp()
        let status = GainKernel.ioProc(0, &time, input.pointer, &time, output.pointer, &time, nil)
        #expect(status == noErr)
    }
}

@Suite("Latency estimate")
struct AudioLatencyTests {
    @Test("Added latency is input latency + input safety offset + one IO buffer")
    func added() {
        // The aggregate device's figures as read live on MacBook Pro Speakers at 48 kHz.
        let latency = AudioLatency(
            sampleRate: 48000, bufferFrames: 512, inputLatencyFrames: 33, inputSafetyOffsetFrames: 48,
            outputLatencyFrames: 60, outputSafetyOffsetFrames: 48
        )
        #expect(latency.addedFrames == 593)
        #expect(abs(latency.addedMilliseconds - 12.354) < 0.001)
        #expect(AudioLatency(
            sampleRate: 0, bufferFrames: 1, inputLatencyFrames: 0, inputSafetyOffsetFrames: 0,
            outputLatencyFrames: 0, outputSafetyOffsetFrames: 0
        ).addedMilliseconds == 0)
    }
}
