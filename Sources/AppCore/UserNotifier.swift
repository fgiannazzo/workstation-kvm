import Foundation
import UserNotifications

/// What became of a request to show a notification.
public enum NotificationOutcome: Sendable, Equatable {
    case posted
    /// Not shown, and why (no bundle, permission refused, the system said no). The caller logs it.
    case skipped(String)
}

/// Shows a notification. Behind a protocol so `AppModel` is tested without the system's centre.
public protocol UserNotifier: Sendable {
    func post(title: String, body: String) async -> NotificationOutcome
}

/// `UNUserNotificationCenter`. Asks for permission the first time something is posted, not at
/// launch, so starting the app never shows a dialog. Without permission (or outside an `.app`,
/// where the centre cannot be used at all) nothing is shown and the outcome says why.
public final class SystemNotifier: UserNotifier {
    private let presenter = ForegroundPresenter()

    public init() {}

    private static var isInBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    public func post(title: String, body: String) async -> NotificationOutcome {
        // `UNUserNotificationCenter.current()` raises an exception when there is no bundle.
        guard Self.isInBundle else { return .skipped("not running from an app bundle") }
        let center = UNUserNotificationCenter.current()
        center.delegate = presenter

        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            status = await center.notificationSettings().authorizationStatus
        }
        guard status == .authorized || status == .provisional else {
            return .skipped("notifications for Switchboard are not allowed (System Settings > Notifications)")
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        do {
            try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            return .posted
        } catch {
            return .skipped("the system refused the notification: \(error.localizedDescription)")
        }
    }
}

/// A menu bar app counts as frontmost while its popover is open; without this the system would
/// swallow a notification posted then.
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
