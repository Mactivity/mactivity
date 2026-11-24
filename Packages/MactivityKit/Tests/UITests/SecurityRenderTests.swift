import AppKit
import Core
import Simulated
import SwiftUI
import Testing
@testable import UI

/// The Security page (D-261), from the simulated Mac, and without Full Disk Access.
extension NewFeaturesRenderTests {
    struct NoAccess: SecuritySource {
        func settings() async -> SecuritySettings {
            await SimulatedSecurity().settings()
        }

        func permissions() async -> PermissionsReading {
            .noAccess
        }

        func systemExtensions() async -> [SystemExtensionItem] {
            []
        }

        func browserExtensions() async -> BrowserExtensionsReading {
            let simulated = await SimulatedSecurity().browserExtensions()
            return BrowserExtensionsReading(extensions: simulated.extensions.filter { $0.browser == .safari }, blocked: [.chrome, .edge])
        }
    }

    /// macOS 27 with Full Disk Access: the system's file only.
    struct Partial: SecuritySource {
        func settings() async -> SecuritySettings {
            await SimulatedSecurity().settings()
        }

        func permissions() async -> PermissionsReading {
            guard case let .read(found, _) = await SimulatedSecurity().permissions() else {
                return .noAccess
            }
            return .read(found.filter { !PermissionKind.perUser.contains($0.kind) }, unreadable: PermissionKind.perUser)
        }

        func systemExtensions() async -> [SystemExtensionItem] {
            []
        }

        func browserExtensions() async -> BrowserExtensionsReading {
            BrowserExtensionsReading(extensions: [], blocked: [])
        }
    }

    @Test("The Security page")
    func securityPage() async throws {
        for (name, source) in [
            ("security", SimulatedSecurity() as any SecuritySource),
            ("security-no-access", NoAccess()),
            ("security-partial", Partial()),
        ] {
            let services = AppServices.preview()
            services.securitySource = source
            await services.security.load()
            try await write(SecurityView(services: services), name: name, size: CGSize(width: 900, height: 1250))
        }
    }
}
