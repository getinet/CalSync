import Foundation
import UserNotifications
import CalSyncCore

/// Because the app has no window, notifications are the only way a failure becomes
/// visible without the user going looking. Every call is best-effort.
@MainActor
enum Notifier {
    private static var authorized = false

    static func requestAuthorizationIfNeeded() async {
        do {
            authorized = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert])
        } catch {
            authorized = false
            Log.write("WARN notification authorization failed: \(error.localizedDescription)")
        }
    }

    static func post(title: String, body: String, policy: NotificationPolicy, isError: Bool) {
        switch policy {
        case .off: return
        case .errors where !isError: return
        default: break
        }
        guard authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.write("WARN could not post notification: \(error.localizedDescription)")
            }
        }
    }
}
