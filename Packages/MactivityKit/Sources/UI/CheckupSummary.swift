import Core
import SwiftUI

/// "Worth doing soon: 2 · Worth knowing: 3", with a way into Checkup (D-107). Loads when it
/// appears, never per tick, so it costs nothing while the menu bar window is closed. Shows nothing
/// when Checkup has nothing to say.
struct CheckupLine: View {
    let services: AppServices
    let open: () -> Void

    @State private var items: [CheckupItem] = []

    var body: some View {
        Group {
            if !items.isEmpty {
                Button(action: open) {
                    HStack(spacing: Tokens.Spacing.xs) {
                        Image(systemName: attention > 0 ? "exclamationmark.circle.fill" : "checkmark.seal")
                            .foregroundStyle(attention > 0 ? Tokens.Colors.strain : Color.accentColor)
                        Text(CheckupView.summary(items))
                            .lineLimit(1)
                        Spacer(minLength: Tokens.Spacing.xs)
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(items.prefix(3).map(\.title).joined(separator: "\n"))
            }
        }
        .task(id: services.historyGeneration) {
            items = await Checkup.items(CheckupLoader.inputs(services))
        }
    }

    private var attention: Int {
        items.count { $0.severity == .attention }
    }
}

/// The menu bar window's notices (D-107): Checkup, what's keeping the Mac awake, and accessory
/// batteries. Each appears only when it has something to say.
struct MenuBarNotices: View {
    /// Accessories on the notices' line before the rest fold into "+2".
    static let accessoriesShown = 4

    let services: AppServices
    let openCheckup: () -> Void

    @State private var blockers: [SleepBlocker] = []

    var body: some View {
        let accessories = services.metrics.snapshot?.system.sensors?.peripherals ?? []
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            CheckupLine(services: services, open: openCheckup)
            if !blockers.isEmpty {
                HStack(spacing: Tokens.Spacing.xs) {
                    Image(systemName: "moon.zzz")
                        .foregroundStyle(.indigo)
                    Text(SleepBlockersBanner.text(blockers))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    // The same sign the Checkup line above has that it leads somewhere (D-197).
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
                // History → Sleep, which says what each one is doing (D-196).
                .onTapGesture { services.navigation.showHistory(.sleep) }
                .accessibilityAddTraits(.isButton)
                .help(blockers.map { "\($0.app.name): \($0.reason)" }.joined(separator: "\n"))
            }
            if !accessories.isEmpty {
                // Room for four: the lowest first, then "+2" (D-176: six wrapped "45 %" onto two lines).
                let shown = accessories.sorted { $0.percent < $1.percent }.prefix(Self.accessoriesShown)
                HStack(spacing: Tokens.Spacing.m) {
                    ForEach(shown) { device in
                        HStack(spacing: Tokens.Spacing.xxs) {
                            Image(systemName: DeviceBatteryRow.symbol(device.kind))
                                .foregroundStyle(device.percent <= 20 ? Tokens.Colors.strain : .secondary)
                            Text(Formatters.percent(device.percent))
                                .monospacedDigit()
                        }
                        .fixedSize()
                        .help(device.name)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(verbatim: "\(device.name), \(Formatters.percent(device.percent))"))
                    }
                    if accessories.count > shown.count {
                        Text(verbatim: "+\(accessories.count - shown.count)")
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .help(accessories.map { "\($0.name): \(Formatters.percent($0.percent))" }.joined(separator: "\n"))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                // History → Accessories, each one's charge over time (D-197).
                .contentShape(.rect)
                .onTapGesture { services.navigation.showHistory(.accessories) }
                .accessibilityAddTraits(.isButton)
            }
        }
        .font(Tokens.Typography.secondary)
        .task {
            blockers = await services.sleepBlockers.blockers().filter { $0.keeps == .system && $0.isUserFacing }
        }
    }
}
