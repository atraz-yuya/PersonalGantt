import Foundation
#if os(iOS)
import BackgroundTasks
#endif

/// Opportunistic refresh only; foreground always reconciles independently.
@MainActor enum BackgroundCalendarRefresh {
    static let identifier = "com.atraz.PersonalGantt.calendar-refresh"
    static func scheduleNext() {
        #if os(iOS)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(30 * 60)
        if #available(iOS 27.0, *) {
            _Concurrency.Task { try? await BGTaskScheduler.shared.submitTaskRequest(request) }
        } else { try? BGTaskScheduler.shared.submit(request) }
        #endif
    }
}
