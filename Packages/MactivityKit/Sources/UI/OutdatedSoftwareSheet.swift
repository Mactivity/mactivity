import AppKit
import Core
import Projects
import SwiftUI

/// Outdated Software (D-252), from Checkup: what needs updating for security, each with how to
/// update it, and Upgrade for Homebrew formulae after a confirmation.
struct OutdatedSoftwareSheet: View {
    @Bindable var model: OutdatedSoftwareModel

    var body: some View {
        let findings = model.findings()
        let checksVulnerabilities = model.checksVulnerabilities
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            header
            if model.isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            } else if findings.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "Nothing needs updating", bundle: .strings), systemImage: "checkmark.shield")
                } description: {
                    Text(Self.emptyDetail(checks: checksVulnerabilities))
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                List {
                    ForEach(findings, id: \.item.id) { finding in
                        row(finding.item, finding.concern)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 260)
            }
            footer(findings)
        }
        .padding(Tokens.Spacing.l)
        .frame(width: 600)
        .confirmationDialog(
            Self.confirmTitle(model.confirming ?? []),
            isPresented: Binding(get: { model.confirming != nil }, set: {
                if !$0 {
                    model.cancelUpgrade()
                }
            }),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Upgrade", bundle: .strings, comment: "Outdated Software: confirms brew upgrade")) {
                Task { await model.confirmUpgrade() }
            }
            Button(String(localized: "Cancel", bundle: .strings), role: .cancel) { model.cancelUpgrade() }
        } message: {
            Text(Self.confirmMessage(model.plan))
        }
        .alert(model.outcome ?? "", isPresented: Binding(get: { model.outcome != nil }, set: {
            if !$0 {
                model.outcome = nil
            }
        })) {
            Button(String(localized: "OK", bundle: .strings)) {}
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.s) {
            Image(systemName: "shippingbox")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                Text("Outdated Software", bundle: .strings)
                    .font(Tokens.Typography.headline)
                Text(
                    """
                    Packages and languages on this Mac that no longer get security fixes, or have known \
                    vulnerabilities: from Homebrew, version managers like pyenv and nvm, and Apple's own.
                    """,
                    bundle: .strings
                )
                .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ item: InstalledSoftware, _ concern: SoftwareConcern) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
            Image(systemName: Self.symbol(concern))
                .foregroundStyle(Self.tint(concern))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.titleWithVersion)
                    .lineLimit(1)
                Text(Self.detail(item, concern))
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    // The vulnerabilities themselves, on hover: "CVE-2025-10016: Local privilege escalation…".
                    .help(Text(verbatim: item.vulnerabilities.map { "\($0.id): \($0.summary)" }.joined(separator: "\n")))
            }
            Spacer()
            action(item, concern)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func action(_ item: InstalledSoftware, _ concern: SoftwareConcern) -> some View {
        if let command = Self.moveCommand(item, concern) {
            copyButton(command)
        } else if item.origin == .homebrew {
            Button(String(localized: "Upgrade…", bundle: .strings, comment: "Outdated Software: one Homebrew formula")) {
                Task { await model.askToUpgrade([item.name]) }
            }
            .disabled(model.isUpgrading)
        } else if item.origin == .appUpdater, let path = item.path {
            // The app's own Check for Updates replaces its updater too.
            Button(String(localized: "Open App", bundle: .strings, comment: "Outdated Software: opens an app to update it")) {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
            .help(Text("Open it and choose Check for Updates.", bundle: .strings))
        } else if let command = InstalledSoftwareParsing.command(for: item) {
            copyButton(command)
        }
    }

    private func copyButton(_ command: String) -> some View {
        Button(String(localized: "Copy Command", bundle: .strings)) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
        .help(Text(verbatim: command))
    }

    /// A Homebrew line that's over needs the current formula, not an upgrade on the old line.
    static func moveCommand(_ item: InstalledSoftware, _ concern: SoftwareConcern) -> String? {
        guard case .unsupported = concern, let formula = item.replacementFormula else {
            return nil
        }
        return "brew install \(formula)"
    }

    private func footer(_ findings: [(item: InstalledSoftware, concern: SoftwareConcern)]) -> some View {
        let formulae = findings.filter { $0.item.origin == .homebrew && Self.moveCommand($0.item, $0.concern) == nil }.map(\.item.name)
        return VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(spacing: Tokens.Spacing.s) {
                Text(Self.checkStatus(model, checks: model.checksVulnerabilities))
                    .font(Tokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if model.isChecking || model.isUpgrading {
                    ProgressView().controlSize(.small)
                }
                if model.checksVulnerabilities {
                    Button(String(localized: "Check Now", bundle: .strings, comment: "Outdated Software: runs the vulnerability check")) {
                        Task { await model.checkNow() }
                    }
                    .disabled(model.isChecking)
                }
            }
            HStack {
                if formulae.count > 1 {
                    Button(String(localized: "Upgrade All from Homebrew…", bundle: .strings)) {
                        Task { await model.askToUpgrade(formulae) }
                    }
                    .disabled(model.isUpgrading)
                }
                Spacer()
                Button(String(localized: "Done", bundle: .strings)) { model.isPresented = false }
                    .keyboardShortcut(.defaultAction)
                    .background {
                        Button("") { model.isPresented = false }
                            .keyboardShortcut(.cancelAction)
                            .hidden()
                    }
            }
        }
    }

    // MARK: Words

    static func emptyDetail(checks: Bool) -> String {
        checks
            ? String(
                localized: "Nothing installed is past its end of life, and Homebrew's packages have no known vulnerabilities.",
                bundle: .strings
            )
            : String(
                localized: """
                Nothing installed is past its end of life. To check Homebrew's packages for known vulnerabilities \
                too, turn it on in Settings → Privacy.
                """,
                bundle: .strings
            )
    }

    /// "3 known vulnerabilities, the worst high · Homebrew", "No security fixes since Dec 31, 2025 · pyenv".
    static func detail(_ item: InstalledSoftware, _ concern: SoftwareConcern) -> String {
        let what = switch concern {
        case let .vulnerable(severity):
            String(
                localized: "\(item.vulnerabilities.count) known vulnerabilities, the worst \(severityName(severity))",
                bundle: .strings,
                comment: "Outdated Software: how many, and the highest severity, e.g. high"
            )
        case let .unsupported(since?):
            String(
                localized: "No security fixes since \(since.formatted(date: .abbreviated, time: .omitted))",
                bundle: .strings,
                comment: "Outdated Software: a runtime past its end of life"
            )
        case .unsupported(nil):
            String(localized: "No longer supported by Homebrew", bundle: .strings)
        case let .endingSoon(date):
            String(
                localized: "Security fixes end \(date.formatted(date: .abbreviated, time: .omitted))",
                bundle: .strings,
                comment: "Outdated Software: a runtime's end of life soon"
            )
        case .deprecated:
            String(localized: "Deprecated by Homebrew", bundle: .strings)
        case .outdated:
            if item.origin == .apple, item.name == "ruby" {
                String(localized: "Comes with macOS, and is updated with it", bundle: .strings)
            } else if item.origin == .apple {
                String(localized: "Comes with Xcode's tools, and is updated with them", bundle: .strings)
            } else if let latest = item.latest {
                String(localized: "Version \(latest) is out", bundle: .strings, comment: "Outdated Software")
            } else {
                String(localized: "A newer version is out", bundle: .strings)
            }
        }
        let source = item.component.map { "\(origin(item.origin)), \($0)" } ?? origin(item.origin)
        return "\(what) · \(source)"
    }

    static func severityName(_ severity: Vulnerability.Severity) -> String {
        switch severity {
        case .critical: String(localized: "critical", bundle: .strings, comment: "Vulnerability severity")
        case .high: String(localized: "high", bundle: .strings, comment: "Vulnerability severity")
        case .medium: String(localized: "medium", bundle: .strings, comment: "Vulnerability severity")
        case .low: String(localized: "low", bundle: .strings, comment: "Vulnerability severity")
        case .unknown: String(localized: "not rated", bundle: .strings, comment: "Vulnerability severity: none given")
        }
    }

    static func origin(_ origin: InstalledSoftware.Origin) -> String {
        switch origin {
        case .homebrew: "Homebrew"
        case .homebrewCask: String(localized: "Homebrew app", bundle: .strings, comment: "A Homebrew cask")
        case .pyenv: "pyenv"
        case .nvm: "nvm"
        case .fnm: "fnm"
        case .volta: "Volta"
        case .rbenv: "rbenv"
        case .asdf: "asdf"
        case .mise: "mise"
        case .apple: "Apple"
        case .homebrewItself: "Homebrew"
        case .appUpdater: String(
                localized: "Its built-in updater",
                bundle: .strings,
                comment: "Outdated Software: an app's Sparkle updater"
            )
        }
    }

    static func symbol(_ concern: SoftwareConcern) -> String {
        switch concern {
        case .vulnerable: "exclamationmark.shield.fill"
        case .unsupported: "xmark.shield.fill"
        case .endingSoon: "clock.badge.exclamationmark"
        case .deprecated, .outdated: "arrow.up.circle"
        }
    }

    static func tint(_ concern: SoftwareConcern) -> Color {
        if concern.isUrgent {
            return .red
        }
        return switch concern {
        case .vulnerable, .endingSoon: .orange
        default: .secondary
        }
    }

    static func checkStatus(_ model: OutdatedSoftwareModel, checks: Bool) -> String {
        guard checks else {
            return String(
                localized: "End of life only. Settings → Privacy can also check Homebrew's packages for known vulnerabilities.",
                bundle: .strings
            )
        }
        guard let scan = model.scan else {
            return String(localized: "Not checked for vulnerabilities yet.", bundle: .strings)
        }
        let when = scan.at.formatted(.relative(presentation: .named))
        return scan.skipped.isEmpty
            ? String(localized: "Checked for known vulnerabilities \(when).", bundle: .strings, comment: "e.g. 2 hours ago")
            : String(
                localized: "Checked for known vulnerabilities \(when). Homebrew couldn't check \(scan.skipped.count).",
                bundle: .strings,
                comment: "e.g. 2 hours ago; then how many packages it couldn't check"
            )
    }

    static func confirmTitle(_ formulae: [String]) -> String {
        String(
            localized: "Upgrade \(formulae.formatted(.list(type: .and)))?",
            bundle: .strings,
            comment: "Outdated Software: confirmation title, Homebrew formula names"
        )
    }

    static func confirmMessage(_ plan: [String]) -> String {
        let note = String(
            localized: """
            Homebrew updates itself, then upgrades these and anything that depends on them. Services they run \
            keep the old version until they restart.
            """,
            bundle: .strings
        )
        return plan.isEmpty ? note : plan.joined(separator: "\n") + "\n\n" + note
    }
}
