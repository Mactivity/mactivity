import AppKit
import Charts
import Core
import SwiftUI

/// "Your next Mac" as one US Letter page (D-181): the same view on screen and in the PDF, so
/// what you read is what you save. Light, always: it's a document.
struct NextMacPage: View {
    let report: NextMacReport

    static let size = CGSize(width: 612, height: 792)
    static let brand = [Color(red: 0.20, green: 0.52, blue: 1.00), Color(red: 0.36, green: 0.22, blue: 0.86)]

    private var advice: UpgradeAdvice {
        report.advice
    }

    func content(_ detail: NeedCard.Detail, showsDay: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            NextMacHero(report: report)
            if let desk = advice.desk {
                NextMacDesk(desk: desk, advice: advice)
            }
            let cards = advice.needs.filter { $0.kind != .battery }
            Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 10) {
                ForEach(Array(stride(from: 0, to: cards.count, by: 2)), id: \.self) { index in
                    GridRow {
                        NeedCard(need: cards[index], detail: detail)
                        if index + 1 < cards.count {
                            NeedCard(need: cards[index + 1], detail: detail)
                        } else {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }
            if showsDay {
                NextMacDayChart(advice: advice)
            }
            if let battery = advice.need(.battery) {
                BatteryStrip(need: battery)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            NextMacHeader(report: report)
            if advice.needs.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(LinearGradient(colors: Self.brand, startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text("Not enough history yet. Mactivity records every minute; come back after a day of use.", bundle: .strings)
                        .font(.system(size: 12))
                        .foregroundStyle(NextMacStyle.muted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // The fullest version that fits the page: a long language drops the evidence
                // lines first, then the meters' captions and the apps (D-181).
                ViewThatFits(in: .vertical) {
                    content(.full)
                    content(.brief)
                    content(.minimal)
                    content(.minimal, showsDay: false)
                }
            }
            Spacer(minLength: 0)
            NextMacFooter(report: report)
        }
        .padding(36)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(Color.white)
        .foregroundStyle(Color(white: 0.11))
        .environment(\.colorScheme, .light)
    }
}

// MARK: - Header and footer

private struct NextMacHeader: View {
    let report: NextMacReport

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your next Mac", bundle: .strings, comment: "Report title: what to look for in a new Mac")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color(white: 0.45))
            }
            Spacer()
            Text((report.start ..< report.end).formatted(.interval.month(.abbreviated).day().year()))
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Color(white: 0.45))
        }
    }

    /// "From 30 days on this MacBook Pro · Apple M5 Pro · 36 GB · 1 TB".
    private var subtitle: String {
        let specs = [report.macName, report.chip, Formatters.memory(report.installedMemory)]
            + (report.diskCapacity > 0 ? [Formatters.bytes(report.diskCapacity)] : [])
        return String(
            localized: "From \(report.days) days on this \(specs.joined(separator: " · "))",
            bundle: .strings,
            comment: "Report subtitle: days of history, then this Mac's name, chip, memory and disk"
        )
    }
}

private struct NextMacFooter: View {
    let report: NextMacReport

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if report.advice.isEarly, !report.advice.needs.isEmpty {
                Text(
                    "A first look, from \(UpgradeText.hours(report.advice.hoursRecorded)) of history. It firms up after a few days of use.",
                    bundle: .strings
                )
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(Color(red: 0.75, green: 0.42, blue: 0.0))
            }
            HStack(alignment: .firstTextBaseline) {
                Text(
                    """
                    Made by Mactivity from this Mac's own history; nothing left the Mac. \
                    What to look for, not a quote: prices and models change.
                    """,
                    bundle: .strings
                )
                Spacer(minLength: 12)
                Text(verbatim: "mactivity.app")
            }
            .font(.system(size: 7.5))
            .foregroundStyle(Color(white: 0.55))
        }
    }
}

// MARK: - The recommendation

private struct NextMacHero: View {
    let report: NextMacReport

    private var advice: UpgradeAdvice {
        report.advice
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("RECOMMENDED", bundle: .strings, comment: "Report: above the recommended Mac")
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.75))
                Text(verbatim: advice.form.name)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                HStack(spacing: 6) {
                    ForEach(specs, id: \.self) { spec in
                        Text(spec)
                            .font(.system(size: 10.5, weight: .semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(.white.opacity(0.18), in: .capsule)
                    }
                }
                Text(advice.formReason)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: advice.form.symbol)
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.35))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: NextMacPage.brand, startPoint: .topLeading, endPoint: .bottomTrailing),
            in: .rect(cornerRadius: 16)
        )
    }

    /// "Pro chip", "48 GB memory", "2 TB storage".
    private var specs: [String] {
        var specs = [advice.need(.processor).map { _ in UpgradeText.chip(advice.chip) }].compactMap(\.self)
        if advice.memoryVerdict > 0 {
            specs.append(String(localized: "\(UpgradeText.gigabytes(advice.memoryVerdict)) memory", bundle: .strings))
        }
        if advice.storageVerdict > 0 {
            specs.append(String(localized: "\(UpgradeText.storage(Double(advice.storageVerdict) / 1e12)) storage", bundle: .strings))
        }
        return specs
    }
}
