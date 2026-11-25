import GameCore
import UserNotifications

/// A macOS notification when a launch can't get anywhere while Corkscrew isn't in front: a player
/// who pressed Play and went on with something else would otherwise come back to a launcher that
/// never started the game. A click opens the game's page (`ReportNotifications.Delegate`).
enum LaunchNotifications {
    static func postStuck(_ game: Game, program: String) {
        let content = UNMutableNotificationContent()
        content.title = "\(program) is stuck"
        content.body = "\(game.name) won't start. Force Stop it in Corkscrew, then Play again."
        content.sound = .default
        content.threadIdentifier = "launch"
        content.userInfo = ["game": game.id.uuidString]
        let request = UNNotificationRequest(identifier: "launch-\(game.id)-\(UUID().uuidString)", content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            do { try await center.add(request) } catch { print("Couldn't show a launch notification: \(error)") }
        }
    }
}
