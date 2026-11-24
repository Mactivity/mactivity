import Core
import SwiftUI

/// What shows while the keyboard is locked for cleaning (D-203): how to get it back and when it
/// comes back by itself. The pointer still works, so Unlock is a click away.
public struct KeyboardLockView: View {
    let endsAt: Date
    let unlock: () -> Void

    public init(endsAt: Date, unlock: @escaping () -> Void) {
        self.endsAt = endsAt
        self.unlock = unlock
    }

    public var body: some View {
        VStack(spacing: Tokens.Spacing.m) {
            Image(systemName: "keyboard")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: Tokens.Spacing.xs) {
                Text("Keyboard locked for cleaning", bundle: .strings)
                    .font(Tokens.Typography.headline)
                    .multilineTextAlignment(.center)
                Text("Wipe away: keys do nothing until you unlock it.", bundle: .strings)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = Duration.seconds(max(0, endsAt.timeIntervalSince(context.date)).rounded(.up))
                Text("Unlocks by itself in \(left.formatted(.time(pattern: .minuteSecond)))", bundle: .strings)
                    .font(Tokens.Typography.secondary)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button(action: unlock) {
                Text("Unlock", bundle: .strings, comment: "Ends the keyboard cleaning lock")
                    .frame(minWidth: 120)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            Text("Or press ⌃⌥K again.", bundle: .strings, comment: "Keyboard lock: the shortcut that ends it")
                .font(Tokens.Typography.secondary)
                .foregroundStyle(.secondary)
        }
        .padding(Tokens.Spacing.xl)
        .frame(width: 480)
    }
}
