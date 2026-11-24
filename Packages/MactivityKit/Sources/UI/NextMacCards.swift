import Charts
import Core
import SwiftUI

/// The parts of "Your next Mac" (D-181): a card per need, its meter and fit, the average day.
enum NextMacStyle {
    static let card = Color(white: 0.965)
    static let muted = Color(white: 0.45)

    static func tint(_ kind: UpgradeAdvice.Kind) -> Color {
        switch kind {
        case .processor: MetricTab.cpu.tint
        case .memory: MetricTab.memory.tint
        case .graphics: MetricTab.gpu.tint
        case .storage: MetricTab.disk.tint
        case .battery: MetricTab.battery.tint
        }
    }

    static func symbol(_ kind: UpgradeAdvice.Kind) -> String {
        switch kind {
        case .processor: "cpu"
        case .memory: "memorychip"
        case .graphics: "cube.transparent"
        case .storage: "internaldrive"
        case .battery: "battery.75percent"
        }
    }

    static func title(_ kind: UpgradeAdvice.Kind) -> String {
        switch kind {
        case .processor: String(localized: "Processor", bundle: .strings, comment: "Next Mac card")
        case .memory: String(localized: "Memory", bundle: .strings)
        case .graphics: String(localized: "Graphics", bundle: .strings, comment: "Next Mac card: the GPU")
        case .storage: String(localized: "Storage", bundle: .strings)
        case .battery: String(localized: "Battery", bundle: .strings)
        }
    }

    /// How this Mac fits the work, as a word and a color.
    static func fit(_ fit: UpgradeAdvice.Fit) -> (String, Color) {
        switch fit {
        case .plenty: (
                String(localized: "Plenty of room", bundle: .strings, comment: "Next Mac: this Mac has room to spare"),
                Color(red: 0.13, green: 0.6, blue: 0.3)
            )
        case .comfortable: (
                String(localized: "Comfortable", bundle: .strings, comment: "Next Mac: this Mac fits well"),
                Color(red: 0.05, green: 0.5, blue: 0.62)
            )
        case .tight: (
                String(localized: "Tight", bundle: .strings, comment: "Next Mac: this Mac is near its limit"),
                Color(red: 0.8, green: 0.45, blue: 0.0)
            )
        case .short: (
                String(localized: "Too small", bundle: .strings, comment: "Next Mac: this Mac runs out"),
                Color(red: 0.8, green: 0.16, blue: 0.14)
            )
        }
    }
}

struct NeedCard: View {
    /// How much a card says: all of it, without the evidence lines, or the essentials only.
    enum Detail {
        case full, brief, minimal
    }

    let need: UpgradeAdvice.Need
    var detail = Detail.full

    private var minimumHeight: CGFloat {
        switch detail {
        case .full: 150
        case .brief: 132
        case .minimal: 112
        }
    }

    var body: some View {
        let tint = NextMacStyle.tint(need.kind)
        let (fitText, fitColor) = NextMacStyle.fit(need.fit)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: NextMacStyle.symbol(need.kind)).foregroundStyle(tint)
                Text(NextMacStyle.title(need.kind)).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(NextMacStyle.muted)
                Spacer(minLength: 4)
                Text(fitText)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(fitColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(fitColor.opacity(0.12), in: .capsule)
            }
            .font(.system(size: 10))
            Text(need.verdict).font(.system(size: 18, weight: .bold, design: .rounded))
            if let usage = need.usage {
                UsageMeter(usage: usage, tint: tint, single: need.kind == .storage, showsCaption: detail != .minimal)
            }
            Text(need.headline)
                .font(.system(size: 8.8))
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 1.5) {
                if detail == .full {
                    Text(need.evidence.joined(separator: " · "))
                }
                if let app = need.topApp, detail != .minimal {
                    Text("Most of it: \(app)", bundle: .strings, comment: "Next Mac card: the app behind the use")
                }
            }
            .font(.system(size: 8))
            .foregroundStyle(NextMacStyle.muted)
            .monospacedDigit()
        }
        .padding(11)
        // A floor per level keeps a row's two cards close in height without stretching them to
        // whatever they're offered, which would hide how tall the page really is.
        .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .topLeading)
        .background(NextMacStyle.card, in: .rect(cornerRadius: 12))
    }
}

/// This Mac's capacity as the track: typical use light, busy use full, the peak as a tick.
struct UsageMeter: View {
    let usage: UpgradeAdvice.Usage
    let tint: Color
    /// Storage has one figure: what's used.
    var single = false
    var showsCaption = true

    var body: some View {
        // Room under the bar for the peak tick, which stands 2 pt proud of it, before the caption.
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(white: 0.88))
                    Capsule().fill(tint.opacity(0.85)).frame(width: max(4, width * min(1, usage.busy)))
                    if !single {
                        Capsule().fill(tint.opacity(0.4)).frame(width: max(4, width * min(1, usage.typical)))
                        Rectangle().fill(tint.opacity(0.95))
                            .frame(width: 2, height: 12)
                            .offset(x: max(0, width * min(1, usage.peak) - 1))
                    }
                }
            }
            .frame(height: 8)
            if showsCaption {
                caption
            }
        }
    }

    private var caption: some View {
        Text(single
            ? String(localized: "Used, of this Mac's disk", bundle: .strings)
            : String(localized: "Typical · busy · peak, of what this Mac has", bundle: .strings))
            .font(.system(size: 7))
            .foregroundStyle(NextMacStyle.muted)
    }
}

/// The average day, hour by hour: processor and graphics busy, memory in use, the busiest
/// stretch shaded.
struct NextMacDayChart: View {
    let advice: UpgradeAdvice

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your average day", bundle: .strings, comment: "Report: the 24-hour profile")
                    .font(.system(size: 11, weight: .semibold))
                if let busiest = advice.busiestHours {
                    Text(busiestText(busiest)).font(.system(size: 8.5)).foregroundStyle(NextMacStyle.muted)
                }
                Spacer()
                legend
            }
            chart.frame(height: 82)
        }
        .padding(10)
        .background(NextMacStyle.card, in: .rect(cornerRadius: 12))
    }

    private var chart: some View {
        Chart {
            if let busiest = advice.busiestHours {
                RectangleMark(xStart: .value("Hour", busiest.lowerBound), xEnd: .value("Hour", busiest.upperBound + 1))
                    .foregroundStyle(MetricTab.cpu.tint.opacity(0.07))
            }
            ForEach(advice.day) { hour in
                AreaMark(x: .value("Hour", hour.hour), y: .value("Processor", hour.cpu), series: .value("Series", "cpu"))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(
                        colors: [MetricTab.cpu.tint.opacity(0.35), MetricTab.cpu.tint.opacity(0.03)], startPoint: .top, endPoint: .bottom
                    ))
                LineMark(x: .value("Hour", hour.hour), y: .value("Processor", hour.cpu), series: .value("Series", "cpu"))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(MetricTab.cpu.tint)
                LineMark(x: .value("Hour", hour.hour), y: .value("Memory", hour.memory), series: .value("Series", "memory"))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(MetricTab.memory.tint)
                if let gpu = hour.gpu {
                    LineMark(x: .value("Hour", hour.hour), y: .value("Graphics", gpu), series: .value("Series", "gpu"))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                        .foregroundStyle(MetricTab.gpu.tint)
                }
            }
        }
        .chartYScale(domain: 0 ... 100)
        .chartXScale(domain: 0 ... 23)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine().foregroundStyle(Color(white: 0.85))
                AxisValueLabel { Text(Formatters.percent(value.as(Double.self) ?? 0)).font(.system(size: 7)) }
            }
        }
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                AxisValueLabel { Text(Self.hourLabel(value.as(Int.self) ?? 0)).font(.system(size: 7)) }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            item(String(localized: "Processor", bundle: .strings, comment: "Next Mac card"), MetricTab.cpu.tint)
            item(String(localized: "Memory", bundle: .strings), MetricTab.memory.tint)
            if advice.day.contains(where: { $0.gpu != nil }) {
                item(String(localized: "Graphics", bundle: .strings, comment: "Next Mac card: the GPU"), MetricTab.gpu.tint)
            }
        }
        .font(.system(size: 7.5))
        .foregroundStyle(NextMacStyle.muted)
    }

    private func item(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
        }
    }

    /// "Busiest 10 AM – 1 PM", in the locale's own interval style, as the page's dates are.
    private func busiestText(_ hours: ClosedRange<Int>) -> String {
        let day = Calendar.current.startOfDay(for: Date())
        let start = day.addingTimeInterval(Double(hours.lowerBound) * 3600)
        let end = day.addingTimeInterval(Double(hours.upperBound + 1) * 3600)
        let range = (start ..< end).formatted(.interval.hour())
        return String(localized: "Busiest \(range)", bundle: .strings, comment: "Report: the busiest hours of the average day")
    }

    static func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(from: DateComponents(hour: hour % 24)) ?? Date()
        return date.formatted(.dateTime.hour())
    }
}

struct BatteryStrip: View {
    let need: UpgradeAdvice.Need

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "battery.75percent")
                .font(.system(size: 16))
                .foregroundStyle(NextMacStyle.tint(.battery))
            VStack(alignment: .leading, spacing: 2) {
                Text(need.verdict).font(.system(size: 11, weight: .semibold))
                Text(need.headline).font(.system(size: 8.8)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(need.evidence.first ?? "").font(.system(size: 8)).foregroundStyle(NextMacStyle.muted).monospacedDigit()
        }
        .padding(10)
        .background(NextMacStyle.card, in: .rect(cornerRadius: 12))
    }
}

/// The desk the advice rests on (D-237): the displays and the lid, what they mean for the pick,
/// and another Mac to weigh.
struct NextMacDesk: View {
    let desk: DeskUsage
    let advice: UpgradeAdvice

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "display.2")
                Text("YOUR DESK", bundle: .strings, comment: "Report: the displays and lid the advice rests on")
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(1.2)
            }
            .foregroundStyle(NextMacStyle.muted)
            Text(UpgradeText.desk(desk))
                .font(.system(size: 11, weight: .semibold))
            ForEach(advice.deskNotes, id: \.self) { note in
                Text(note).font(.system(size: 9.5)).foregroundStyle(NextMacStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
            if let alternative = advice.alternative {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: alternative.form.symbol).font(.system(size: 10))
                    Text(verbatim: alternative.form.name).font(.system(size: 10, weight: .semibold))
                    Text(alternative.reason).font(.system(size: 9.5)).foregroundStyle(NextMacStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NextMacStyle.card, in: .rect(cornerRadius: 12))
    }
}
