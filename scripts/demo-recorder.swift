// Films one app's main window to an MP4 (D-124), for scripts/demo-video.sh:
//   demo-recorder check                              # 2 s of any window, written nowhere: can this terminal record?
//   demo-recorder record <pid> <output.mp4> <max s> [min frames]  # that process's main window, until it quits or max s
// ScreenCaptureKit captures that window alone, so whatever else is on screen, or on top of it,
// stays out of the video. Needs Screen Recording for the terminal running it.
//
// It runs as an (invisible) app: ScreenCaptureKit needs the window server connection
// NSApplication makes, and its callbacks need a main thread that isn't blocked.
// Exit codes: 0 done, 2 usage, 3 no Screen Recording, 4 no window, 5 too few frames, 6 cut short or
// cropped (worth trying again), 1 anything else.
import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

final class Recorder: NSObject, SCStreamOutput, @unchecked Sendable {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    private var started = false
    private(set) var frames = 0
    private let queue = DispatchQueue(label: "demo-recorder")

    init(output: URL, width: Int, height: Int) throws {
        writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        super.init()
    }

    var sampleQueue: DispatchQueue {
        queue
    }

    /// Frames written so far, read from any thread.
    var written: Int {
        queue.sync { frames }
    }

    func stream(_: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid, Self.isComplete(buffer) else {
            return
        }
        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: buffer.presentationTimeStamp)
            started = true
        }
        if input.isReadyForMoreMediaData, input.append(buffer) {
            frames += 1
        }
    }

    /// Only frames with new content; idle and blank ones carry no image.
    static func isComplete(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw)
        else {
            return false
        }
        return status == .complete
    }

    /// Finishes the file; the number of frames written.
    func finish() async -> Int {
        await withCheckedContinuation { continuation in
            queue.async {
                guard self.started else {
                    continuation.resume(returning: 0)
                    return
                }
                self.input.markAsFinished()
                let frames = self.frames
                self.writer.finishWriting { continuation.resume(returning: frames) }
            }
        }
    }
}

/// The windows ScreenCaptureKit can film. Without Screen Recording this throws, or on some
/// systems returns no windows at all; both mean the same thing here.
func windows() async -> [SCWindow] {
    do {
        return try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false).windows
    } catch {
        fail(
            "This terminal can't record the screen (\(error.localizedDescription)). Turn it on in System Settings → "
                + "Privacy & Security → Screen & System Audio Recording, quit and reopen the terminal, and run again.",
            3
        )
    }
}

func largest(_ windows: [SCWindow]) -> SCWindow? {
    windows
        .filter { $0.windowLayer == 0 && $0.frame.width > 400 && $0.frame.height > 300 }
        .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
}

func mainWindow(of pid: Int32) async -> SCWindow? {
    await largest(windows().filter { $0.owningApplication?.processID == pid })
}

/// Films `window` until `keepGoing` says stop or `limit` passes. `follow` gives the window's frame
/// now, so filming a display area keeps up if the window moves; `resized` says it changed size,
/// which leaves part of it outside the video. `filming` runs once the first frame is in (or after
/// 3 s without one), the moment a recording really starts.
func film(
    _ window: SCWindow, to output: URL, limit: Double, follow: (() async -> CGRect?)? = nil,
    filming: (() -> Void)? = nil, keepGoing: () async -> Bool
) async throws -> (frames: Int, seconds: Int, resized: Bool) {
    try? FileManager.default.removeItem(at: output)
    // 1.5× the window in points: sharp, and well under a 4K encoder's limits. Even sizes for H.264.
    let width = Int(window.frame.width * 1.5) / 2 * 2
    let height = Int(window.frame.height * 1.5) / 2 * 2
    let recorder = try Recorder(output: output, width: width, height: height)
    let configuration = SCStreamConfiguration()
    configuration.width = width
    configuration.height = height
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    configuration.showsCursor = false
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    // Filming the window, or including its app, makes macOS badge the window as shared (a purple
    // pill over its buttons). RECORD_DISPLAY_AREA=1 (scripts/media.sh) films the display in that
    // window's area with every other app left out instead: Mactivity's windows, sheets included,
    // and nothing that passes over them.
    var filter = SCContentFilter(desktopIndependentWindow: window)
    var area: (display: CGRect, window: CGRect)?
    if ProcessInfo.processInfo.environment["RECORD_DISPLAY_AREA"] != nil,
       let app = window.owningApplication,
       let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
       let display = content.displays.first(where: { $0.frame.intersects(window.frame) }) {
        let others = content.applications.filter { $0.processID != app.processID }
        filter = SCContentFilter(display: display, excludingApplications: others, exceptingWindows: [])
        configuration.sourceRect = window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        area = (display.frame, window.frame)
        print("Filming the display area of process \(app.processID), \(others.count) other apps left out")
    }
    let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
    try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.sampleQueue)
    try await stream.startCapture()
    let start = Date()
    var signalled = filming == nil
    var resized = false
    while Date().timeIntervalSince(start) < limit, await keepGoing() {
        try await Task.sleep(for: .milliseconds(signalled ? 500 : 50))
        if !signalled, recorder.written > 0 || Date().timeIntervalSince(start) > 3 {
            filming?()
            signalled = true
        }
        // The area is fixed when filming starts; move it with the window (same size, new place).
        if let current = area, let frame = await follow?(), frame != current.window {
            if frame.size == current.window.size {
                configuration.sourceRect = frame.offsetBy(dx: -current.display.minX, dy: -current.display.minY)
                try? await stream.updateConfiguration(configuration)
                area = (current.display, frame)
            } else {
                resized = true
            }
        }
    }
    try? await stream.stopCapture()
    return await (recorder.finish(), Int(Date().timeIntervalSince(start)), resized)
}

func check() async throws {
    let own = ProcessInfo.processInfo.processIdentifier
    guard let window = await largest(windows().filter { $0.isOnScreen && $0.owningApplication?.processID != own }) else {
        fail(
            "This terminal can't see any windows to record. Turn on Screen Recording for it (System Settings → "
                + "Privacy & Security → Screen & System Audio Recording), quit and reopen it, and run again.",
            3
        )
    }
    let output = FileManager.default.temporaryDirectory.appendingPathComponent("demo-recorder-check-\(own).mp4")
    defer { try? FileManager.default.removeItem(at: output) }
    let result = try await film(window, to: output, limit: 2) { true }
    // A still window sends one complete frame, then only "idle" ones.
    guard result.frames > 0 else {
        fail("Screen Recording is on, but the test recording came out empty.", 5)
    }
    print("Screen recording works (\(result.frames) frames in 2 s of a test window).")
}

func record(pid: Int32, output: URL, limit: Double, minimumFrames: Int) async throws {
    var window: SCWindow?
    for _ in 0 ..< 40 where window == nil {
        window = await mainWindow(of: pid)
        if window == nil {
            try await Task.sleep(for: .milliseconds(250))
        }
    }
    guard var window else {
        fail("Mactivity's window never appeared (process \(pid)).", 4)
    }
    // A new window opens with a short zoom, smaller than it ends up: filming the area it had then
    // crops the window once it's full size. Start once it has held one frame for a second.
    let id = window.windowID
    let current: () async -> SCWindow? = { await windows().first { $0.windowID == id } }
    var still = 0
    var waited = 0
    while still < 2 {
        guard waited < 30 else {
            fail("Mactivity's window didn't stop moving or resizing in 15 s.", 4)
        }
        try await Task.sleep(for: .milliseconds(500))
        waited += 1
        guard let now = await current() else {
            still = 0
            continue
        }
        still = now.frame == window.frame ? still + 1 : 0
        window = now
    }
    // RECORD_READY_FILE (scripts/media.sh): created once filming has started; the demo tour waits
    // for it (-MeasureDemoReadyFile), so a clip always starts at its beginning.
    let ready = ProcessInfo.processInfo.environment["RECORD_READY_FILE"]
    // Until Mactivity quits (the tour quits it at the end). The window is followed by its ID: a
    // sheet opening can hide it from the list for a moment, and that isn't the end, or a resize.
    let result = try await film(
        window, to: output, limit: limit, follow: { await current()?.frame },
        filming: ready.map { path in { _ = FileManager.default.createFile(atPath: path, contents: nil) } }
    ) {
        kill(pid, 0) == 0
    }
    if kill(pid, 0) == 0 {
        fail("Mactivity was still running after \(Int(limit)) s, so the recording may be cut short.", 6)
    }
    if result.resized {
        fail("Mactivity's window changed size while filming, so part of it is cut off.", 6)
    }
    // The tour changes the window every few seconds; a real recording has hundreds of frames.
    // A short clip of one page has fewer (scripts/media.sh asks for less).
    guard result.frames >= minimumFrames else {
        fail("The recording has only \(result.frames) frames in \(result.seconds) s; something went wrong.", 5)
    }
    print(
        "Recorded \(result.seconds) s, \(result.frames) frames, \(Int(window.frame.width)) × \(Int(window.frame.height)) pt, to \(output.path)"
    )
}

let arguments = CommandLine.arguments
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    do {
        switch arguments.dropFirst().first {
        case "check":
            try await check()
        case "record" where arguments.count == 5 || arguments.count == 6:
            guard let pid = Int32(arguments[2]), let limit = Double(arguments[4]),
                  let minimum = arguments.count == 6 ? Int(arguments[5]) : 30 else {
                fail("usage: demo-recorder record <pid> <output.mp4> <max seconds> [min frames]", 2)
            }
            try await record(pid: pid, output: URL(fileURLWithPath: arguments[3]), limit: limit, minimumFrames: minimum)
        default:
            fail("usage: demo-recorder check | record <pid> <output.mp4> <max seconds> [min frames]", 2)
        }
        exit(0)
    } catch {
        fail("Recording failed: \(error.localizedDescription)", 1)
    }
}

app.run()
