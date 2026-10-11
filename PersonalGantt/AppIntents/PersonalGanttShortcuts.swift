import AppIntents

nonisolated struct PersonalGanttShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddPersonalGanttTaskIntent(),
            phrases: [
                "Add a task to \(.applicationName)",
                "Add a task with \(.applicationName)",
                "Create a task in \(.applicationName)"
            ],
            shortTitle: "タスクを追加",
            systemImageName: "plus.circle"
        )
    }
}
