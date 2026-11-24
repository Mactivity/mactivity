import AppKit
import Core
import Export
import Foundation
import Observation
import os
import SwiftUI

/// Record a moment (D-151): every snapshot, at the visible cadence, into a CSV file the person
/// picked when they started, until they stop or an hour passes. The file is written as it goes,
/// a few seconds at a time, and flushed when the app quits.
@MainActor
@Observable
public final class RecordingModel {
    private static let log = Logger(subsystem: "app.mactivity.ui", category: "recording")
    /// A recording stops by itself after this.
    nonisolated static let limit: TimeInterval = 3600

    public private(set) var startedAt: Date?
    public private(set) var url: URL?
    public private(set) var snapshotCount = 0

    @ObservationIgnored private var handle: FileHandle?
    @ObservationIgnored private var buffer = ""
    @ObservationIgnored private var metrics: LiveMetrics?
    @ObservationIgnored private var limitTask: Task<Void, Never>?
    @ObservationIgnored private var writeFailed = false
    @ObservationIgnored private var quitObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let dates: ISO8601DateFormatter = {
        let dates = ISO8601DateFormatter()
        dates.timeZone = .autoupdatingCurrent
        dates.formatOptions = [.withInternetDateTime]
        return dates
    }()

    /// Told when a recording ends: the app shows a toast.
    @ObservationIgnored public var onFinished: (String) -> Void = { _ in }

    public init() {}

    public var isRecording: Bool {
        startedAt != nil
    }

    /// Asks where to save, then starts.
    public func chooseFileAndStart(metrics: LiveMetrics) {
        let panel = NSSavePanel()
        panel.title = String(localized: "Record Activity", bundle: .strings)
        panel.message = String(
            localized: "Every second's figures, for the Mac and each busy app, until you stop or an hour passes.",
            bundle: .strings
        )
        panel.prompt = String(localized: "Start Recording", bundle: .strings)
        panel.nameFieldStringValue = RecordingCSV.suggestedName(at: Date())
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        start(to: url, metrics: metrics)
    }

    /// Starts writing to `url`, replacing it (the save panel already asked).
    public func start(to url: URL, metrics: LiveMetrics?, now: Date = Date()) {
        // Another recording ends the way Stop would, saying where its file is.
        finish(reveal: false)
        guard FileManager.default.createFile(atPath: url.path, contents: Data((RecordingCSV.header + "\n").utf8)),
              let handle = try? FileHandle(forWritingTo: url) else {
            Self.log.error("Recording: couldn't create the file")
            onFinished(String(localized: "Couldn't create the recording file.", bundle: .strings))
            return
        }
        _ = try? handle.seekToEnd()
        self.handle = handle
        self.url = url
        writeFailed = false
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        self.metrics = metrics
        startedAt = now
        snapshotCount = 0
        metrics?.setVisible(true, surface: .recording)
        limitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.limit))
            guard !Task.isCancelled else {
                return
            }
            self?.finish()
        }
    }

    /// Each snapshot, from the pipeline: nothing to do unless recording.
    public func record(_ snapshot: Snapshot) {
        guard handle != nil else {
            return
        }
        buffer += RecordingCSV.rows(snapshot, dates: dates).joined(separator: "\n") + "\n"
        snapshotCount += 1
        if buffer.utf8.count > 1 << 15 {
            flush()
        }
    }

    /// Stops and says where the file is, or that writing it failed.
    public func finish(reveal: Bool = true) {
        guard let url, isRecording else {
            return
        }
        let count = snapshotCount
        stop()
        guard !writeFailed else {
            onFinished(String(localized: "The recording couldn't be written in full. Is the disk full?", bundle: .strings))
            return
        }
        onFinished(String(localized: "Recording saved: \(count) readings in \(url.lastPathComponent)", bundle: .strings))
        if reveal {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Stops without revealing the file (tests).
    func stopForTesting() {
        stop()
    }

    private func stop() {
        if let quitObserver {
            NotificationCenter.default.removeObserver(quitObserver)
        }
        quitObserver = nil
        limitTask?.cancel()
        limitTask = nil
        flush()
        try? handle?.close()
        handle = nil
        metrics?.setVisible(false, surface: .recording)
        metrics = nil
        startedAt = nil
    }

    private func flush() {
        guard let handle, !buffer.isEmpty else {
            return
        }
        do {
            try handle.write(contentsOf: Data(buffer.utf8))
        } catch {
            Self.log.error("Recording: write failed")
            writeFailed = true
        }
        buffer = ""
    }
}

/// While recording: a red dot, the time so far, and Stop (the main window's toolbar).
struct RecordingIndicator: View {
    let model: RecordingModel

    var body: some View {
        if let startedAt = model.startedAt {
            Button {
                model.finish()
            } label: {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Label {
                        Text(Formatters.duration(.seconds(max(0, context.date.timeIntervalSince(startedAt)))))
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "record.circle.fill").foregroundStyle(.red)
                    }
                    .labelStyle(.titleAndIcon)
                }
            }
            .help(Text("Stop recording and show the file", bundle: .strings))
            .accessibilityLabel(Text("Stop Recording", bundle: .strings))
        }
    }
}
