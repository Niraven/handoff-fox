import Foundation
import UserNotifications

/// Post only what would otherwise be missed: a handoff that lands while the
/// person is in another window, and a job that finishes after they leave.
@MainActor
final class FoxNotifier {
    private var authorized = false
    private let center = UNUserNotificationCenter.current()

    func prepare() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        center.getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                guard let self else { return }
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    self.authorized = true
                case .notDetermined:
                    self.center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                        Task { @MainActor in self.authorized = granted }
                    }
                default:
                    self.authorized = false
                }
            }
        }
    }

    func post(_ title: String, _ body: String) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }
}
