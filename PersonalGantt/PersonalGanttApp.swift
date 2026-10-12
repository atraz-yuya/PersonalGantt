//
//  PersonalGanttApp.swift
//  PersonalGantt
//
//  Created by 広戸佑哉 on 2026/09/27.
//

import SwiftUI
import AppIntents

@main
struct PersonalGanttApp: App {
    @State private var model: ScheduleViewModel

    init() {
        #if DEBUG
        _model = State(initialValue: Bundle.main.bundleIdentifier == "com.atraz.PersonalGantt.UIPreview" || ProcessInfo.processInfo.arguments.contains("--local-sync-handshake-check")
            ? NavigationPreview.makeModel() : ScheduleViewModel.shared)
        #else
        _model = State(initialValue: ScheduleViewModel.shared)
        #endif
        PersonalGanttShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        #if os(macOS)
        // One editor owns the device checkpoint; reopening a window retains its model.
        Window("PersonalGantt", id: "main") {
            rootView
        }
        #else
        WindowGroup {
            rootView
        }
        #if os(iOS)
        .backgroundTask(.appRefresh(BackgroundCalendarRefresh.identifier)) {
            await ScheduleViewModel.shared.performBackgroundRefresh()
        }
        #endif
        #endif
    }
    @ViewBuilder private var rootView: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--local-sync-handshake-check") {
            LocalSyncHandshakeCheckView()
        } else { ContentView(model: model) }
        #else
        ContentView(model: model)
        #endif
    }
}
