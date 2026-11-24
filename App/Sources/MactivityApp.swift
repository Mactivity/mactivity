import Alerts
import AppKit
import Core
import Readouts
import SwiftUI
import UI
import UserNotifications

/// Hosted by the app tests (`xcodebuild test`), Mactivity starts nothing: the tests make their
/// own models, and a full launch would sample, open the real history and
/// look for updates on the developer's Mac, and on CI.
@main
enum MactivityMain {
    static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static func main() {
        if isTestHost {
            TestHostApp.main()
        } else {
            MactivityApp.main()
        }
    }
}

/// An app with no windows and no menu bar item, for the tests to load into.
struct TestHostApp: App {
    var body: some Scene {
        Settings { EmptyView() }
    }
}

struct MactivityApp: App {
    static let mainWindowID = "main"

    /// `--background`, or "Show the main window when Mactivity opens" turned off, starts in the
    /// menu bar only.
    static let launchesInBackground = ProcessInfo.processInfo.arguments.contains("--background")
        || UserDefaults.standard.object(forKey: PreferenceKey.showsWindowAtLaunch) as? Bool == false

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    @AppStorage(PreferenceKey.menuBarMode) private var menuBarMode: MenuBarMode = .icon
    @AppStorage(PreferenceKey.menuBarMetric) private var menuBarMetric: MenuBarMetric = .cpu
    @AppStorage(PreferenceKey.menuBarStackedMetrics) private var stackedRaw = MenuBarMetric.stackedDefault
    @AppStorage(PreferenceKey.menuBarShowsGlyph) private var menuBarShowsGlyph = true
    @AppStorage(PreferenceKey.menuBarGraphShowsValue) private var menuBarGraphShowsValue = true
    @AppStorage(PreferenceKey.appearance) private var appearance: AppearancePreference = .system
    @AppStorage(PreferenceKey.perAppVolume) private var perAppVolume = false

    var body: some Scene {
        @Bindable var model = model

        // WindowGroup, not Window: SwiftUI keeps a closed Window and everything drawn in it for the
        // life of the app, 20 MB once you've been through the tabs (D-270). One value, so asking
        // for the window again brings the open one forward instead of making a second.
        WindowGroup("Mactivity", id: Self.mainWindowID, for: String.self) { _ in
            MainWindowView(services: model.services, isSimulated: $model.isSimulated)
                .frame(minWidth: Tokens.Layout.mainWindowMinimum.width, minHeight: Tokens.Layout.mainWindowMinimum.height)
                .preferredColorScheme(appearance.colorScheme)
                .background(MainWindowFrameMemory())
                .modifier(MeasureCloseWindow(id: Self.mainWindowID))
        } defaultValue: {
            Self.mainWindowID
        }
        .defaultSize(Tokens.Layout.mainWindowDefault)
        // No link makes a window on its own (D-270). AppDelegate handles them all: a Control
        // Center control's link (D-210) does its job without this window.
        .handlesExternalEvents(matching: [])
        .defaultLaunchBehavior(Self.launchesInBackground ? .suppressed : .presented)
        // Launch decides whether the window shows, not last session's state.
        .restorationBehavior(.disabled)
        .windowToolbarStyle(.unified)

        MenuBarExtra {
            MenuBarContent(services: model.services, isSimulated: $model.isSimulated, mainWindowID: Self.mainWindowID)
                .preferredColorScheme(appearance.colorScheme)
        } label: {
            MenuBarLabelHost(
                services: model.services,
                mode: menuBarMode,
                metric: menuBarMetric,
                stacked: MenuBarMetric.decodeList(stackedRaw),
                showsGlyph: menuBarShowsGlyph,
                graphShowsValue: menuBarGraphShowsValue
            )
        }
        .menuBarExtraStyle(.window)
        .commands {
            // There's only one main window, so File has only Close: no New Window, no Close All.
            // Emptying the new-item group alone removes File and with it ⌘W.
            CommandGroup(replacing: .newItem) {
                Button("Close") { NSApplication.shared.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w")
            }
            CommandGroup(replacing: .saveItem) {}
            // Every tab the sidebar shows, in its order; ⌘1–⌘9 for the first nine, like Activity
            // Monitor and Finder's sidebar. The rest (Alerts, History) are a click in this menu.
            CommandGroup(after: .sidebar) {
                Divider()
                // Back and Forward between pages (D-195), as a browser and System Settings.
                Button("Back") { model.services.navigation.goBack() }
                    .keyboardShortcut("[")
                    .disabled(!model.services.navigation.canGoBack)
                Button("Forward") { model.services.navigation.goForward() }
                    .keyboardShortcut("]")
                    .disabled(!model.services.navigation.canGoForward)
                Divider()
                let hasBattery = model.services.metrics.hardware.hasBattery
                ForEach(Array(sidebarItems.enumerated()), id: \.element) { index, item in
                    Button(item.title(hasBattery: hasBattery)) {
                        model.services.navigation.show(item)
                    }
                    .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command) : nil)
                }
                Divider()
                // ⌘R, like reloading: the Storage tab's Scan button does the same.
                Menu("Stay Awake") {
                    KeepAwakeMenuItems(model: model.services.keepAwake)
                }
                Button("Quick Search…") { QuickSearchPanel.shared.show() }
                    .keyboardShortcut("m", modifiers: [.control, .option])
                // Locks every key for cleaning, until ⌃⌥K again, Unlock or five minutes (D-203).
                Button("Clean Keyboard") { KeyboardLockController.shared.lock() }
                    .keyboardShortcut("k", modifiers: [.control, .option])
                Button("Why Is My Mac Slow?") {
                    model.services.navigation.openMainWindow()
                    model.services.slowdown.open(model.services)
                }
                Menu("Save Report") {
                    Button("Last 7 Days…") { ReportPDF.save(model.services, period: .week) }
                    Button("Last 30 Days…") { ReportPDF.save(model.services, period: .month) }
                }
                Button("Your Next Mac…") {
                    model.services.navigation.openMainWindow()
                    model.services.nextMac.open()
                }
                if model.services.recording.isRecording {
                    Button("Stop Recording") { model.services.recording.finish() }
                        .keyboardShortcut("r", modifiers: [.command, .option])
                } else {
                    Button("Record Activity…") { model.services.recording.chooseFileAndStart(metrics: model.services.metrics) }
                        .keyboardShortcut("r", modifiers: [.command, .option])
                }
                Divider()
                Button("Rescan Storage") { model.services.rescanStorage() }
                    .keyboardShortcut("r")
                    .disabled(!model.services.canRescanStorage)
            }
            ProcessCommands(services: model.services)
            CommandGroup(replacing: .appInfo) {
                Button("About Mactivity") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationVersion: BuildInfo.main().displayVersion,
                        .version: "",
                    ])
                    NSApplication.shared.activate()
                }
            }
            CommandGroup(replacing: .help) {
                if let url = FeedbackDraft.url() {
                    Button("Send Feedback…") { NSWorkspace.shared.open(url) }
                }
                if let website = Links.website {
                    Link("Mactivity Website", destination: website)
                }
            }
            CommandGroup(after: .appInfo) {
                if Updates.shared.isConfigured {
                    Button("Check for Updates…") { Updates.shared.checkForUpdates() }
                }
            }
        }

        Settings {
            SettingsView(services: model.services)
                .preferredColorScheme(appearance.colorScheme)
        }
    }

    /// The sidebar's items, in its order: Sound only with per-app volume on.
    private var sidebarItems: [SidebarItem] {
        SidebarItem.allCases.filter { perAppVolume || $0 != .volume }
    }
}

/// The Process menu: acts on the selected row in a metric tab's app list. Shortcuts follow
/// Activity Monitor (⌥⌘Q Quit Process) and Finder (⌘I Get Info, ⇧⌘R Show in Finder). Quit and
/// Force Quit only ask: the confirmation is `ConfirmedAction` (CLAUDE.md rule 4).
private struct ProcessCommands: Commands {
    let services: AppServices

    var body: some Commands {
        CommandMenu("Process") {
            let selection = services.actionableSelection
            Button("Get Info") { services.getInfoOnSelection() }
                .keyboardShortcut("i")
                .disabled(selection?.canGetInfo != true)
            Button("Show in Finder") { services.showSelectionInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(selection?.canShowInFinder != true)
            Divider()
            Button("Quit…") { services.quitSelection(mode: .quit) }
                .keyboardShortcut("q", modifiers: [.command, .option])
                .disabled(selection?.canQuit != true)
            Button("Force Quit…") { services.quitSelection(mode: .forceQuit) }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
                .disabled(selection?.canQuit != true)
        }
    }
}

/// The menu bar label, plus the one always-alive place that can open the main window when a
/// notification deep-links into it.
private struct MenuBarLabelHost: View {
    let services: AppServices
    let mode: MenuBarMode
    let metric: MenuBarMetric
    let stacked: [MenuBarMetric]
    let showsGlyph: Bool
    let graphShowsValue: Bool

    @Environment(\.openWindow) private var openWindow
    /// Settings → General → Figures: what each figure shows, and so how wide the item is.
    @StoredFigureChoices private var choices

    /// Figures the item shows, for filtering redraws that wouldn't visibly change (D-068). Graph
    /// mode counts its metric too: its bars then advance at least once a minute, or as soon as
    /// the figure moves noticeably.
    private var textMetrics: [MenuBarMetric] {
        switch mode {
        case .figure: [metric]
        case .graph: [metric.graphSource]
        case .stacked: stacked
        case .icon: []
        }
    }

    /// Temperature in the menu bar means sensors are read while idle too.
    private var needsSensors: Bool {
        switch mode {
        case .figure: metric == .temperature
        case .stacked: stacked.contains(.temperature)
        case .icon, .graph: false
        }
    }

    var body: some View {
        MenuBarLabel(
            metrics: services.metrics, mode: mode, metric: metric, stacked: stacked,
            showsGlyph: showsGlyph, graphShowsValue: graphShowsValue, choices: choices
        )
        .onChange(of: choices, initial: true) { _, choices in
            services.metrics.figureChoices = choices
        }
        .onChange(of: needsSensors, initial: true) { _, wanted in
            services.metrics.menuBarNeedsSensors = wanted
        }
        .onChange(of: textMetrics, initial: true) { _, shown in
            services.metrics.menuBarTextMetrics = shown
        }
        .onChange(of: services.navigation.openMainWindowRequest) {
            openWindow(id: MactivityApp.mainWindowID, value: MactivityApp.mainWindowID)
            NSApplication.shared.activate()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        UNUserNotificationCenter.current().delegate = self
        // The person's shortcuts (1.6): Quick Search, Clean Keyboard, Stay Awake, pages.
        MainActor.assumeIsolated { ShortcutsController.shared.start() }
    }

    /// Mactivity lives in the menu bar; closing the main window doesn't quit it.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    /// Opening Mactivity again (the Dock, Finder, Spotlight) with no window open shows the main
    /// window: the way back when the menu bar item is hidden, e.g. behind the notch.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            MainActor.assumeIsolated {
                AppModel.shared.services.navigation.openMainWindow()
            }
        }
        return true
    }

    /// Writes the minute in progress before quitting, and a build still under way (D-219). Control
    /// Center's Stay Awake reads off: the power assertion goes with the app.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await BuildRecorder.current?.finish()
            await AppModel.shared.networkRecorder.pause()
            AppModel.shared.controls?.update(stayAwake: false)
            await AppModel.shared.flush()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// `mactivity://control/…` from Control Center's controls (D-210), with this launch's token.
    func application(_: NSApplication, open urls: [URL]) {
        for url in urls {
            // Another Mac's report (1.6): History, with the two Macs side by side.
            if url.isFileURL, url.pathExtension == MacProfile.fileExtension {
                MainActor.assumeIsolated {
                    let services = AppModel.shared.services
                    services.navigation.show(.history)
                    Task { await services.compareMacs.open(url, services: services) }
                }
            } else if let action = ControlLink.action(url, token: AppModel.shared.controls?.token) {
                MainActor.assumeIsolated { Self.perform(action) }
            }
        }
    }

    @MainActor
    private static func perform(_ action: ControlLink.Action) {
        let services = AppModel.shared.services
        switch action {
        case .cleanKeyboard:
            KeyboardLockController.shared.lock()
        case let .stayAwake(on):
            // Until switched off, as the menu's choice; it still lets go on a low battery or heat.
            services.keepAwake.set(on ? .indefinitely : .off)
            AppModel.shared.controls?.update(stayAwake: on)
        case .yourDay:
            services.navigation.showDay(Date())
            NSApplication.shared.activate()
        }
    }

    /// Show alerts even while Mactivity is frontmost.
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    /// Clicking an alert, or its Show button, opens the relevant tab with the app highlighted
    /// (spec 4.4). Its Mute button mutes the app's alerts without bringing Mactivity forward.
    nonisolated func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        // The held alerts' summary (1.6) opens Alerts, on what fired.
        if info[AlertDeepLink.pageKey] as? String == AlertDeepLink.alertsPage {
            await MainActor.run { AppModel.shared.services.navigation.selection = .alerts }
            return
        }
        guard let link = AlertDeepLink.parse(info) else {
            return
        }
        let action = AlertNotificationAction(identifier: response.actionIdentifier)
        await MainActor.run {
            let services = AppModel.shared.services
            switch action {
            case .show:
                if let rule = link.rule {
                    services.navigation.show(rule, app: link.appID)
                } else {
                    services.navigation.show(link.metric.sidebarItem, highlighting: link.appID)
                }
            case .mute: services.setAlertsMuted(true, for: link.appID)
            case .ignore: break
            }
        }
    }
}

/// Keeps the main window where it was left. Closing it destroys it (D-270), and the next one would
/// otherwise start at the default place and size. Our own preference and not an autosave name:
/// SwiftUI's window saves under a name of its own. Screenshots and the demo keep the default size.
private struct MainWindowFrameMemory: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        FrameMemoryView()
    }

    func updateNSView(_: NSView, context _: Context) {}

    private final class FrameMemoryView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !LaunchOverrides.isScreenshotMode, !LaunchOverrides.isDemoTour else {
                return
            }
            if let frame = UserDefaults.standard.string(forKey: PreferenceKey.mainWindowFrame) {
                window.setFrame(from: frame)
                // Left on a display that's gone: AppKit would open it out of reach.
                let titleBar = NSPoint(x: window.frame.midX, y: window.frame.maxY - 10)
                if !NSScreen.screens.contains(where: { $0.frame.contains(titleBar) }) {
                    window.center()
                }
            }
            // Selectors, not closures: a closure holding the window would keep it alive.
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(saveFrame), name: NSWindow.willCloseNotification, object: window)
            center.addObserver(self, selector: #selector(saveFrame), name: NSApplication.willTerminateNotification, object: nil)
        }

        @objc private func saveFrame() {
            guard let window else {
                return
            }
            UserDefaults.standard.set(window.frameDescriptor, forKey: PreferenceKey.mainWindowFrame)
        }
    }
}

/// `-MeasureCloseAfter <seconds>` (scripts/measure.sh): closes the main window after that long,
/// to measure what's left once the window is gone. Does nothing otherwise.
private struct MeasureCloseWindow: ViewModifier {
    let id: String
    @Environment(\.dismissWindow) private var dismissWindow
    private let seconds = UserDefaults.standard.integer(forKey: "MeasureCloseAfter")

    func body(content: Content) -> some View {
        content.task {
            guard seconds > 0 else {
                return
            }
            try? await Task.sleep(for: .seconds(seconds))
            dismissWindow(id: id, value: id)
        }
    }
}
