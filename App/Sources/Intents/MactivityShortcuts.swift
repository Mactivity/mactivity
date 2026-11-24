import AppIntents

/// Phrases for Siri and Spotlight (E6). Every phrase names the app, as App Shortcuts require.
struct MactivityShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetSystemStatsIntent(),
            phrases: [
                "How's my Mac doing in \(.applicationName)",
                "Get system stats from \(.applicationName)",
                "Check my Mac with \(.applicationName)",
            ],
            shortTitle: "System Stats",
            systemImageName: "gauge.with.dots.needle.33percent"
        )
        AppShortcut(
            intent: TopAppsIntent(),
            phrases: [
                "What's using my Mac in \(.applicationName)",
                "Show top apps in \(.applicationName)",
                "Top apps by \(\.$metric) in \(.applicationName)",
            ],
            shortTitle: "Top Apps",
            systemImageName: "list.number"
        )
        AppShortcut(
            intent: ListDevServersIntent(),
            phrases: [
                "List dev servers in \(.applicationName)",
                "What dev servers are running in \(.applicationName)",
            ],
            shortTitle: "Dev Servers",
            systemImageName: "server.rack"
        )
        AppShortcut(
            intent: ShowIdleDevServersIntent(),
            phrases: [
                "Show idle dev servers in \(.applicationName)",
                "Find idle servers with \(.applicationName)",
            ],
            shortTitle: "Idle Dev Servers",
            systemImageName: "moon.zzz"
        )
        AppShortcut(
            intent: GetYourDayIntent(),
            phrases: [
                "How was my day in \(.applicationName)",
                "Get my day from \(.applicationName)",
                "How was \(\.$day) in \(.applicationName)",
            ],
            shortTitle: "Your Day",
            systemImageName: "calendar.day.timeline.leading"
        )
        AppShortcut(
            intent: GetUnusualIntent(),
            phrases: [
                "What's out of the ordinary in \(.applicationName)",
                "Anything unusual in \(.applicationName)",
            ],
            shortTitle: "Out of the Ordinary",
            systemImageName: "sparkle.magnifyingglass"
        )
        AppShortcut(
            intent: GetBuildTimesIntent(),
            phrases: [
                "How are my builds in \(.applicationName)",
                "Get build times from \(.applicationName)",
            ],
            shortTitle: "Build Times",
            systemImageName: "hammer"
        )
        AppShortcut(
            intent: GetAgentTimeIntent(),
            phrases: [
                "How long did my agents work in \(.applicationName)",
                "Get agent time from \(.applicationName)",
            ],
            shortTitle: "Agent Time",
            systemImageName: "sparkles"
        )
    }
}
