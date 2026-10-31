import AppIntents
import BackgroundTasks
import Foundation
import UserNotifications

/// Unofficial fork: what an Apple TV refresh run did.
struct TVRefreshResult: Sendable {
    var refreshed: [String] = []
    var failed: [String] = []
    /// Set when nothing was attempted (no TV apps, no saved password, TV not on the LAN…).
    var skipped: String? = nil

    var ok: Bool { skipped == nil && failed.isEmpty }

    var summary: String {
        if let skipped { return skipped }
        var parts: [String] = []
        if !refreshed.isEmpty { parts.append("Refreshed: \(refreshed.joined(separator: ", ")).") }
        if !failed.isEmpty { parts.append("Failed: \(failed.joined(separator: "; ")).") }
        return parts.isEmpty ? "Nothing to refresh." : parts.joined(separator: " ")
    }
}

/// Unofficial fork: daily auto-refresh of apps installed to Apple TVs.
/// A BGProcessingTask is asked for at the chosen time (iOS decides when it really runs),
/// and a local reminder fires at that time when a TV app is close to expiring.
@MainActor
final class AppleTVAutoRefresh: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = AppleTVAutoRefresh()

    nonisolated static var taskIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "com.hongson117.tvsideload") + ".tvrefresh"
    }
    static let reminderIdentifier = "tvsideload.tvrefresh.reminder"
    private static let enabledKey = "tvRefresh.enabled"
    private static let minutesKey = "tvRefresh.minutes"
    static let lastRunKey = "tvRefresh.lastRun"

    @Published var enabled: Bool = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey); reschedule() }
    }
    /// Minutes after midnight. Default 03:00.
    @Published var minutes: Int = UserDefaults.standard.object(forKey: minutesKey) as? Int ?? 180 {
        didSet { UserDefaults.standard.set(minutes, forKey: Self.minutesKey); reschedule() }
    }
    @Published private(set) var isRunning = false
    @Published private(set) var lastSummary: String?

    var lastRun: Date? { UserDefaults.standard.object(forKey: Self.lastRunKey) as? Date }

    /// For a DatePicker in hour-and-minute mode.
    var time: Date {
        get { Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now }
        set {
            let c = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            minutes = (c.hour ?? 3) * 60 + (c.minute ?? 0)
        }
    }

    func nextFireDate(after date: Date = .now) -> Date {
        Calendar.current.nextDate(
            after: date,
            matching: DateComponents(hour: minutes / 60, minute: minutes % 60, second: 0),
            matchingPolicy: .nextTime) ?? date.addingTimeInterval(24 * 60 * 60)
    }

    // MARK: - Setup

    /// Call once at launch, before the app finishes launching.
    nonisolated func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: .main) { task in
            guard let task = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            MainActor.assumeIsolated { AppleTVAutoRefresh.shared.handle(task) }
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                UNUserNotificationCenter.current().delegate = AppleTVAutoRefresh.shared
                AppleTVAutoRefresh.shared.reschedule()
            }
        }
    }

    /// Re-submits the background task and re-plans the reminder. Cheap; call after any change.
    func reschedule() {
        let scheduler = BGTaskScheduler.shared
        scheduler.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        guard enabled, hasTVApps else {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.reminderIdentifier])
            return
        }
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = nextFireDate()
        try? scheduler.submit(request)
        planReminder()
    }

    private var tvApps: [InstalledApp] { InstallController.shared.apps.filter { $0.deviceID != nil } }
    private var hasTVApps: Bool { !tvApps.isEmpty }

    /// Reminder at the next chosen time, only if by then a TV app expires within 2 days
    /// and hasn't been refreshed in the 24 hours before it.
    private func planReminder() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.reminderIdentifier])
        let fire = nextFireDate()
        let due = tvApps.filter { app in
            guard let exp = app.expiration else { return false }
            return exp <= fire.addingTimeInterval(2 * 86_400) && app.installedAt < fire.addingTimeInterval(-86_400)
        }
        guard !due.isEmpty else { return }
        let names = due.map(\.name).joined(separator: ", ")
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Apple TV apps expire soon"
            content.body = "\(names) expire within 2 days. Tap to refresh now (Apple TV must be on the same Wi-Fi)."
            content.sound = .default
            content.userInfo = ["action": "refreshTV"]
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            center.add(UNNotificationRequest(
                identifier: Self.reminderIdentifier, content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
        }
    }

    // MARK: - Running

    private func handle(_ task: BGProcessingTask) {
        // Ask for tomorrow first, so a crash or expiry doesn't end the chain.
        reschedule()
        let once = CompletionOnce(task)
        let work = Task { @MainActor in
            let result = await AppleTVAutoRefresh.shared.refreshNow()
            once.complete(result.ok || result.skipped != nil)
        }
        task.expirationHandler = {
            work.cancel()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { InstallController.shared.cancel() }
            }
            once.complete(false)
        }
    }

    /// Refreshes every app installed to an Apple TV. Used by the background task,
    /// the reminder, Settings and the App Intent.
    @discardableResult
    func refreshNow() async -> TVRefreshResult {
        guard !isRunning else { return TVRefreshResult(skipped: "A refresh is already running.") }
        isRunning = true
        defer { isRunning = false }
        let result = await InstallController.shared.refreshAppleTVApps()
        if result.skipped == nil { UserDefaults.standard.set(Date.now, forKey: Self.lastRunKey) }
        lastSummary = result.summary
        reschedule()
        return result
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let isTV = response.notification.request.identifier == Self.reminderIdentifier
        completionHandler()
        guard isTV else { return }
        Task { @MainActor in await AppleTVAutoRefresh.shared.refreshNow() }
    }
}

/// Calls setTaskCompleted exactly once.
private final class CompletionOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let task: BGTask
    init(_ task: BGTask) { self.task = task }
    func complete(_ success: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        task.setTaskCompleted(success: success)
    }
}

// MARK: - App Intent (Shortcuts / automations)

struct RefreshAppleTVAppsIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Apple TV apps"
    static let description = IntentDescription("Re-signs and reinstalls every app TV Sideload installed to an Apple TV on this Wi-Fi.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await AppleTVAutoRefresh.shared.refreshNow()
        return .result(dialog: IntentDialog(stringLiteral: result.summary))
    }
}

struct TVSideloadShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RefreshAppleTVAppsIntent(),
            phrases: ["Refresh Apple TV apps in \(.applicationName)"],
            shortTitle: "Refresh Apple TV apps",
            systemImageName: "appletv")
    }
}
