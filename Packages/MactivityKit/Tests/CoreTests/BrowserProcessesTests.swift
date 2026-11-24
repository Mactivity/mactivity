import Core
import Foundation
import Testing

@Suite("A browser's processes by role (D-154)")
struct BrowserProcessesTests {
    @Test("Chromium helpers by name, extensions by argument; Safari's WebKit services")
    func classify() {
        func kind(_ name: String, _ arguments: [String] = [], app: String = "Google Chrome") -> BrowserProcessKind? {
            BrowserProcessKind.classify(name: name, arguments: arguments, appName: app)
        }
        #expect(kind("Google Chrome") == .main)
        #expect(kind("Google Chrome Helper (Renderer)", ["--type=renderer"]) == .pages)
        #expect(kind("Google Chrome Helper (Renderer)", ["--type=renderer", "--extension-process"]) == .extensions)
        #expect(kind("Google Chrome Helper (GPU)") == .gpu)
        #expect(kind("Google Chrome Helper", ["--type=utility", "--utility-sub-type=network.mojom.NetworkService"]) == .network)
        #expect(kind("Google Chrome Helper", ["--type=utility", "--utility-sub-type=storage.mojom.StorageService"]) == .utility)
        #expect(kind("chrome_crashpad_handler") == nil)
        #expect(kind("com.apple.WebKit.WebContent", app: "Safari") == .pages)
        #expect(kind("com.apple.WebKit.GPU", app: "Safari") == .gpu)
        #expect(kind("com.apple.WebKit.Networking", app: "Safari") == .network)
        #expect(BrowserProcessKind.needsArguments("Brave Browser Helper (Renderer)"))
        #expect(!BrowserProcessKind.needsArguments("Brave Browser Helper (GPU)"))
    }

    @Test("Groups sum the figure per role, largest first; nothing to split for a plain app")
    func groups() {
        let app = AppIdentity(id: "com.google.Chrome", name: "Google Chrome", bundleID: "com.google.Chrome", iconKey: "c", kind: .app)
        func process(_ pid: Int32, _ name: String, cpu: Double) -> ProcessSample {
            ProcessSample(
                pid: pid, app: app.id, name: name, cpuPercent: cpu, footprintBytes: 100, diskReadBPS: 0, diskWriteBPS: 0,
                energyMW: nil, netInBPS: nil, netOutBPS: nil, gpuPercent: nil
            )
        }
        let processes = [
            process(1, "Google Chrome", cpu: 2), process(2, "Google Chrome Helper (Renderer)", cpu: 5),
            process(3, "Google Chrome Helper (Renderer)", cpu: 4), process(4, "Google Chrome Helper (Renderer)", cpu: 1),
            process(5, "Google Chrome Helper (GPU)", cpu: 3),
        ]
        let groups = BrowserProcessKind.groups(
            processes, appName: "Google Chrome", metric: .cpu, arguments: [4: ["--extension-process"]]
        )
        #expect(groups?.map(\.kind) == [.pages, .gpu, .main, .extensions])
        #expect(groups?.first?.count == 2)
        #expect(groups?.first?.value == 9)
        let plain = [process(1, "Xcode", cpu: 1), process(2, "SourceKitService", cpu: 1), process(3, "a", cpu: 1), process(4, "b", cpu: 1)]
        #expect(BrowserProcessKind.groups(plain, appName: "Xcode", metric: .cpu, arguments: [:]) == nil)
    }

    @Test("An Electron app's main process is the one its helpers are named after")
    func mainName() {
        let names = ["Code", "Code Helper", "Code Helper (Renderer)", "Code Helper (GPU)"]
        #expect(BrowserProcessKind.mainName(names, appName: "Visual Studio Code") == "Code")
        #expect(BrowserProcessKind.mainName(["Safari", "com.apple.WebKit.WebContent"], appName: "Safari") == "Safari")
        #expect(BrowserProcessKind.needsArguments("Google Chrome Helper"))
    }
}
