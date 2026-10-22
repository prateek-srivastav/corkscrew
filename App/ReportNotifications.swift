import AppKit
import UserNotifications

/// macOS notifications for news on a report: they come in at the top right, also when Corkscrew
/// isn't in front, and a click opens the Reports page. Without permission, only the sidebar's dot says so.
enum ReportNotifications {
    /// Asks once, after the user sent or added a report, not at launch.
    static func ask() {
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    /// One notification per issue: a newer one removes the last. A request that only replaces a
    /// notification still in Notification Center shows no banner, so each gets its own identifier.
    /// `isFix`: the fix popup shows it too.
    static func post(issue: Int, title: String, body: String, isFix: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "reports"
        content.userInfo = ["issue": issue, "fix": isFix]
        let prefix = "report-\(issue)-"
        let request = UNNotificationRequest(identifier: prefix + UUID().uuidString, content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            let older = await center.deliveredNotifications().map(\.request.identifier).filter { $0.hasPrefix(prefix) }
            center.removeDeliveredNotifications(withIdentifiers: older)
            do { try await center.add(request) } catch { print("Couldn't show a report notification: \(error)") }
        }
    }

    /// Takes the clicks; set before the app finishes launching, so a click that opens the app counts.
    static let delegate = Delegate()

    final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        /// In front, the banner shows too, except for a fix: the fix popup says it.
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
            -> UNNotificationPresentationOptions {
            notification.request.content.userInfo["fix"] as? Bool == true ? [.list] : [.banner, .list, .sound]
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
            await MainActor.run { AppModel.shared.openReports() }
        }
    }
}
