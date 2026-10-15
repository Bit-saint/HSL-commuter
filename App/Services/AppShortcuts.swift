import AppIntents

struct CommuterShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartCommuteIntent(),
                    phrases: ["Start my commute in \(.applicationName)", "When's my bus in \(.applicationName)"],
                    shortTitle: "Start Commute", systemImageName: "tram.fill")
    }
}
