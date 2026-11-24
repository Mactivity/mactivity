import Foundation
import Observation
import SwiftUI

/// After an update, Overview says so once, with this version's release notes a click away
/// (D-179). Updates that install themselves never showed Sparkle's notes. A fresh install says
/// nothing: there's nothing new to someone who just arrived.
@MainActor
@Observable
public final class WhatsNewModel {
    /// The version whose notes wait to be read; nil once seen or dismissed.
    public private(set) var pendingVersion: String?
    public var isPresented = false
    private(set) var notes: [String] = []

    @ObservationIgnored private let defaults: UserDefaults?
    static let lastSeenKey = "whatsNew.lastSeenVersion"
    /// Stands for any version from before the key existed.
    static let earlierVersion = "earlier"

    /// Inert: previews and tests.
    public init() {
        defaults = nil
    }

    /// Compares this build with the last version that ran here.
    public init(version: String, defaults: UserDefaults, bundle: Bundle = .main) {
        self.defaults = defaults
        // Versions before 1.0.6 didn't record themselves: someone who finished onboarding has
        // run an earlier one, so this launch is an update.
        let lastSeen = defaults.string(forKey: Self.lastSeenKey)
            ?? (defaults.bool(forKey: PreferenceKey.hasCompletedOnboarding) ? Self.earlierVersion : nil)
        defaults.set(version, forKey: Self.lastSeenKey)
        // A first launch records the version and stays quiet; so does a version without notes.
        guard let lastSeen, lastSeen != version else {
            return
        }
        let notes = Self.notes(version: version, bundle: bundle)
        if !notes.isEmpty {
            self.notes = notes
            pendingVersion = version
        }
    }

    /// Already pending: render tests.
    init(pending version: String, notes: [String]) {
        defaults = nil
        pendingVersion = version
        self.notes = notes
    }

    public func open() {
        isPresented = true
    }

    public func dismiss() {
        isPresented = false
        pendingVersion = nil
    }

    /// The "- " lines of `releases/<version>.md` in the app's resources (docs/releases).
    nonisolated static func notes(version: String, bundle: Bundle) -> [String] {
        guard let url = bundle.url(forResource: version, withExtension: "md", subdirectory: "releases"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return lines(text)
    }

    nonisolated static func lines(_ text: String) -> [String] {
        text.split(separator: "\n")
            .filter { $0.hasPrefix("- ") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Overview's one line after an update.
struct WhatsNewBanner: View {
    let model: WhatsNewModel

    var body: some View {
        if let version = model.pendingVersion {
            HStack(spacing: Tokens.Spacing.s) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Tokens.Colors.accent)
                    .accessibilityHidden(true)
                Text("Mactivity was updated to \(version).", bundle: .strings, comment: "Overview, after an update: the new version")
                    .lineLimit(1)
                Spacer(minLength: Tokens.Spacing.s)
                Button(String(localized: "What’s New", bundle: .strings, comment: "Opens this version's release notes")) { model.open() }
                    .fixedSize()
                Button {
                    model.dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help(Text("Dismiss", bundle: .strings))
                .accessibilityLabel(Text("Dismiss", bundle: .strings))
            }
            .cardStyle()
        }
    }
}

/// This version's release notes.
struct WhatsNewSheet: View {
    let model: WhatsNewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            Text(
                "What’s new in Mactivity \(model.pendingVersion ?? "")",
                bundle: .strings,
                comment: "Release notes sheet title, with the version"
            )
            .font(Tokens.Typography.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                    ForEach(Array(model.notes.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.xs) {
                            Text(verbatim: "•").foregroundStyle(.secondary)
                            // The notes use **bold** for new features, as on the changelog page.
                            Text((try? AttributedString(markdown: line)) ?? AttributedString(line))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Tokens.Layout.diagnosisListMaxHeight)
            HStack {
                if let changelog = URL(string: "https://mactivity.app/changelog") {
                    Link(
                        String(localized: "Every version’s changes", bundle: .strings, comment: "Link to the website's changelog"),
                        destination: changelog
                    )
                }
                Spacer()
                Button(String(localized: "Done", bundle: .strings)) { model.dismiss() }
                    .keyboardShortcut(.defaultAction)
                    // Esc closes it too, as Return does: an information sheet has nothing to cancel (D-196).
                    .background {
                        Button("") { model.dismiss() }
                            .keyboardShortcut(.cancelAction)
                            .hidden()
                    }
            }
        }
        .padding(Tokens.Spacing.l)
        .frame(width: 520)
    }
}

@MainActor
extension AppServices {
    /// At launch: reopen on the last page (D-174), and after an update offer what's new (D-179).
    public func restoreLaunchState(from defaults: UserDefaults, version: String) {
        navigation.remember(in: defaults)
        whatsNew = WhatsNewModel(version: version, defaults: defaults)
    }
}
