import AppKit
import SwiftUI
import Testing
@testable import UI

/// Onboarding opens as a sheet before anything else: it must stay on a laptop's screen in any
/// language (D-175). Under `make test-pseudo` its doubled text needed 854 pt.
@MainActor
struct OnboardingFitTests {
    init() {
        _ = PseudoLocalization.isOn
    }

    @Test("Onboarding is no taller than its cap")
    func fits() async throws {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: OnboardingView(services: .preview()) {})
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: Tokens.Layout.onboardingWidth, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        for _ in 0 ..< 5 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        let size = hosting.fittingSize
        window.close()
        #expect(size.height <= Tokens.Layout.onboardingMaxHeight, "onboarding is \(size.height) pt tall")
        #expect(size.width <= Tokens.Layout.onboardingWidth + 1, "onboarding is \(size.width) pt wide")
    }
}
