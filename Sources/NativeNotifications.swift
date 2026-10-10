import Foundation
import UserNotifications
import UIKit

@MainActor
final class GuanpanAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        BackgroundQuoteRefresh.perform(completion: completionHandler)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }
}

@MainActor
enum BackgroundQuoteRefresh {
    static let enabledKey = "guanpan.native.backgroundRefresh.enabled"
    private(set) static var store: PortfolioStore?

    static func configure(store: PortfolioStore) {
        self.store = store
        let enabled = UserDefaults.standard.bool(forKey: enabledKey) && store.data.quoteRefreshSeconds > 0
        UIApplication.shared.setMinimumBackgroundFetchInterval(enabled ? UIApplication.backgroundFetchIntervalMinimum : UIApplication.backgroundFetchIntervalNever)
    }

    static func perform(completion: @escaping (UIBackgroundFetchResult) -> Void) {
        guard UserDefaults.standard.bool(forKey: enabledKey), let store, store.data.quoteRefreshSeconds > 0 else {
            completion(.noData); return
        }
        Task { @MainActor in
            let updated = await store.refreshQuotesForBackground()
            completion(updated ? .newData : .failed)
        }
    }
}

@MainActor
enum NativeNotifications {
    static func requestPermission() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func send(title: String, body: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        let request = UNNotificationRequest(identifier: "guanpan-\(UUID().uuidString)", content: content, trigger: trigger)
        try await UNUserNotificationCenter.current().add(request)
    }
}
