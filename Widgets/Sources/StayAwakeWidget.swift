import AppIntents
import Readouts
import SwiftUI
import WidgetKit

/// Stay Awake on the desktop (1.6): its state, and a switch that works from the widget, through
/// the same link as Control Center's control (D-210).
struct StayAwakeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ControlLink.stayAwakeWidgetKind, provider: StayAwakeProvider()) { entry in
            StayAwakeWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Stay Awake")
        .description("Keep your Mac awake from the desktop. It still lets go on a low battery or when hot.")
        .supportedFamilies([.systemSmall])
    }
}

struct StayAwakeEntry: TimelineEntry {
    let date: Date
    /// Nil until Mactivity has run once (and in unsigned builds, without the shared container).
    let isOn: Bool?
}

struct StayAwakeProvider: TimelineProvider {
    func placeholder(in _: Context) -> StayAwakeEntry {
        StayAwakeEntry(date: Date(), isOn: false)
    }

    func getSnapshot(in _: Context, completion: @escaping (StayAwakeEntry) -> Void) {
        completion(StayAwakeEntry(date: Date(), isOn: ControlsFile.state?.stayAwake))
    }

    /// Mactivity reloads it whenever Stay Awake changes; no schedule of its own.
    func getTimeline(in _: Context, completion: @escaping (Timeline<StayAwakeEntry>) -> Void) {
        completion(Timeline(entries: [StayAwakeEntry(date: Date(), isOn: ControlsFile.state?.stayAwake)], policy: .never))
    }
}

struct StayAwakeWidgetView: View {
    let entry: StayAwakeEntry

    var body: some View {
        if let isOn = entry.isOn {
            VStack(alignment: .leading, spacing: WidgetStyle.small) {
                Image(systemName: isOn ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(isOn ? AnyShapeStyle(.orange.gradient) : AnyShapeStyle(.secondary))
                Spacer(minLength: 0)
                Text("Stay Awake").font(WidgetStyle.label)
                Toggle(isOn: isOn, intent: StayAwakeIntent()) {
                    Text(isOn ? "On" : "Off")
                        .font(WidgetStyle.detail)
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                .tint(.orange)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            OpenAppView(detail: "Open Mactivity once to use Stay Awake here.")
        }
    }
}
