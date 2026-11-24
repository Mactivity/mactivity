import Core
import Foundation
import IOKit.pwr_mgt
import Observation
import os
import SwiftUI

/// Stay Awake (D-147, renamed D-162): one switch that stops the Mac idle-sleeping, for a while or until turned
/// off, through a power assertion like `caffeinate`'s (public IOKit). It ends by itself at its
/// time, on a low battery, or when the Mac gets hot. Not with the lid closed: that needs root.
@MainActor
@Observable
public final class KeepAwakeModel {
    public enum Mode: Equatable, Sendable {
        case off
        case until(Date)
        case indefinitely
    }

    private static let log = Logger(subsystem: "app.mactivity.ui", category: "keepawake")
    /// What macOS lists as the reason, in Activity Monitor and `pmset -g assertions`.
    static let assertionName = "Mactivity: Stay Awake"
    /// On battery at or below this, it turns itself off.
    nonisolated static let lowBatteryPercent = 10.0

    public private(set) var mode = Mode.off
    /// The display stays on too, not only the Mac. Kept between launches (D-197).
    public var keepsDisplayOn = UserDefaults.standard.bool(forKey: PreferenceKey.keepAwakeDisplay) {
        didSet {
            UserDefaults.standard.set(keepsDisplayOn, forKey: PreferenceKey.keepAwakeDisplay)
            guard keepsDisplayOn != oldValue, mode != .off else {
                return
            }
            apply(mode)
        }
    }

    /// Why it last turned itself off, for a toast; nil after a manual change.
    public private(set) var endedBecause: String?
    /// Told when it turns itself off: the app shows a toast.
    @ObservationIgnored public var onEnded: (String) -> Void = { _ in }

    @ObservationIgnored private var assertion: IOPMAssertionID = 0
    /// When it was on, the last two days: a night it kept awake isn't "didn't sleep" (D-147).
    @ObservationIgnored private var onSpans: [(start: Date, end: Date?)] = []
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored private var reading: () -> (battery: BatteryStats?, thermal: ThermalPressure?) = { (nil, nil) }

    public init() {}

    public var isOn: Bool {
        mode != .off
    }

    /// Reads the battery and heat from the live figures, for turning itself off.
    public func watch(_ metrics: LiveMetrics) {
        reading = { [weak metrics] in
            let system = metrics?.snapshot?.system
            return (system?.battery, system?.thermal)
        }
    }

    public func set(_ mode: Mode) {
        endedBecause = nil
        apply(mode)
    }

    public func keepAwake(for duration: Duration, now: Date = Date()) {
        set(.until(now.addingTimeInterval(TimeInterval(duration.components.seconds))))
    }

    private func apply(_ mode: Mode, now: Date = Date()) {
        release()
        if mode == .off, let last = onSpans.last, last.end == nil {
            onSpans[onSpans.count - 1].end = now
        } else if mode != .off, onSpans.last.map({ $0.end != nil }) ?? true {
            onSpans.append((now, nil))
        }
        onSpans.removeAll { ($0.end ?? now) < now.addingTimeInterval(-2 * 86400) }
        self.mode = mode
        guard mode != .off else {
            watch?.cancel()
            watch = nil
            return
        }
        let type = keepsDisplayOn ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        var id = IOPMAssertionID(0)
        let status = IOPMAssertionCreateWithName(
            type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), Self.assertionName as CFString, &id
        )
        guard status == kIOReturnSuccess else {
            Self.log.error("Stay Awake: assertion refused (\(status))")
            self.mode = .off
            if let last = onSpans.last, last.end == nil {
                onSpans[onSpans.count - 1].end = Date()
            }
            return
        }
        assertion = id
        startWatching()
    }

    private func release() {
        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }

    /// Every 30 s: its time is up, the battery is low, or the Mac is hot.
    private func startWatching() {
        watch?.cancel()
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else {
                    return
                }
                let reading = reading()
                if let reason = Self.reasonToStop(mode: mode, now: Date(), battery: reading.battery, thermal: reading.thermal) {
                    Self.log.info("Stay Awake ended by itself")
                    apply(.off)
                    endedBecause = reason
                    onEnded(reason)
                    return
                }
            }
        }
    }

    /// Whether it was on at any time between two dates.
    public func wasOn(from: Date, to: Date, now: Date = Date()) -> Bool {
        onSpans.contains { $0.start < to && ($0.end ?? now) > from }
    }

    /// Pure: why Stay Awake should end now, or nil.
    nonisolated static func reasonToStop(mode: Mode, now: Date, battery: BatteryStats?, thermal: ThermalPressure?) -> String? {
        if case let .until(end) = mode, now >= end {
            return String(localized: "Stay Awake is over; your Mac can sleep again.", bundle: .strings)
        }
        if let battery, battery.source == .battery, battery.percent <= lowBatteryPercent {
            return String(localized: "Stay Awake stopped because the battery is running low.", bundle: .strings)
        }
        if let thermal, thermal >= .serious {
            return String(localized: "Stay Awake stopped so your Mac can cool down.", bundle: .strings)
        }
        return nil
    }

    /// "Until 4:30 PM", "Until turned off", or nil when off.
    public var summary: String? {
        switch mode {
        case .off:
            nil
        case let .until(end):
            String(localized: "Awake until \(end.formatted(date: .omitted, time: .shortened))", bundle: .strings)
        case .indefinitely:
            String(localized: "Awake until you switch it off", bundle: .strings)
        }
    }
}

/// Stay Awake's menu, for the menu bar window and the View menu (D-147).
public struct KeepAwakeMenu: View {
    @Bindable var model: KeepAwakeModel

    public init(model: KeepAwakeModel) {
        self.model = model
    }

    public var body: some View {
        Menu {
            KeepAwakeMenuItems(model: model)
        } label: {
            Image(systemName: model.isOn ? "cup.and.saucer.fill" : "cup.and.saucer")
                .foregroundStyle(model.isOn ? Color.accentColor : Color.primary)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text(model.summary ?? String(localized: "Stay Awake", bundle: .strings)))
        .accessibilityLabel(Text("Stay Awake", bundle: .strings))
        .accessibilityValue(Text(model.summary ?? String(localized: "Off", bundle: .strings)))
    }
}

/// Stay Awake's choices, the same in the menu bar window and the View menu (D-196): what it's
/// doing now and Turn Off when it's on, the spans, and the display.
public struct KeepAwakeMenuItems: View {
    @Bindable var model: KeepAwakeModel

    public init(model: KeepAwakeModel) {
        self.model = model
    }

    public var body: some View {
        if let summary = model.summary {
            Text(summary)
            Button(String(localized: "Turn Off", bundle: .strings)) { model.set(.off) }
            Divider()
        } else if let ended = model.endedBecause {
            // Why it stopped on its own, where it was turned on: the toast shows only in the
            // main window (D-197).
            Text(ended)
            Divider()
        }
        Button(String(localized: "For 1 Hour", bundle: .strings)) { model.keepAwake(for: .seconds(3600)) }
        Button(String(localized: "For 2 Hours", bundle: .strings)) { model.keepAwake(for: .seconds(2 * 3600)) }
        Button(String(localized: "For 4 Hours", bundle: .strings)) { model.keepAwake(for: .seconds(4 * 3600)) }
        Button(String(localized: "Until You Switch It Off", bundle: .strings)) { model.set(.indefinitely) }
        Divider()
        Toggle(String(localized: "Keep the Display On Too", bundle: .strings), isOn: $model.keepsDisplayOn)
    }
}
