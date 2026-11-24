@testable import Docker
import Foundation
import Testing

/// Docker disk use (D-224), from a `/system/df` body.
struct DockerDiskTests {
    @Test("Totals and what nothing uses, as docker system df adds them")
    func totals() throws {
        let usage = try DockerDiskMath.usage(json: Data(FakeDockerDaemon.fixture("docker-system-df.json")))
        let byPart = Dictionary(uniqueKeysWithValues: usage.totals.map { ($0.part, $0) })
        // Layers are shared: the total is LayersSize; in use are the two used images' own parts.
        #expect(byPart[.images]?.bytes == 9_000_000_000)
        let inUse: UInt64 = 3_000_000_000 + 2_000_000_000
        #expect(byPart[.images]?.reclaimable == 9_000_000_000 - inUse)
        // A volume whose size the engine didn't compute (-1) isn't counted.
        #expect(byPart[.volumes]?.count == 2)
        #expect(byPart[.volumes]?.bytes == 1_000_000_000)
        #expect(byPart[.volumes]?.reclaimable == 200_000_000)
        // Shared cache records belong to another build too.
        #expect(byPart[.buildCache]?.bytes == 600_000_000)
        #expect(byPart[.buildCache]?.reclaimable == 500_000_000)
        #expect(byPart[.containers]?.reclaimable == 30_000_000)
        let storefront: UInt64 = 2_000_000_000 + 800_000_000 + 50_000_000
        #expect(usage.projects.map(\.project) == ["storefront"])
        #expect(usage.projects.first?.bytes == storefront)
    }

    @Test("Every part has the command that reclaims it")
    func commands() {
        #expect(DockerDiskUsage.Part.allCases.allSatisfy { $0.command.hasPrefix("docker ") && $0.command.contains("prune") })
        #expect(DockerDiskUsage.Part.buildCache.command == "docker builder prune -a")
    }
}
