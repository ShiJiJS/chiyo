// Cleanup only: never dispatch a notification or simulate its click callback.
// Build in a disposable .app with this exact synthetic QA bundle identity.
import Cocoa
import UserNotifications

let identity = "org.shijijs.agent-info-manage.qa.notifications20261021"
guard Bundle.main.bundleIdentifier == identity, CommandLine.arguments.count == 3,
      UUID(uuidString: CommandLine.arguments[1]) != nil,
      !CommandLine.arguments[2].isEmpty else {
  fputs("Invalid synthetic notification cleanup target\n", stderr)
  exit(64)
}
let identifier = CommandLine.arguments[1]
let requestId = CommandLine.arguments[2]
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let center = UNUserNotificationCenter.current()
let deadline = Date().addingTimeInterval(10)
var originalMatches = 0

func finish(_ remaining: Int) {
  let facts: [String: Any] = ["bundleIdentifier": identity,
    "notificationIdentifier": identifier, "requestId": requestId,
    "matchedBefore": originalMatches, "remainingAfter": remaining,
    "permissionRequests": 0, "notificationsSubmitted": 0,
    "clickCallbacksInjected": 0]
  let data = try! JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys])
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data("\n".utf8))
  exit(remaining == 0 ? 0 : 1)
}

func verifyRemoval() {
  center.getDeliveredNotifications { notifications in
    let remaining = notifications.filter { $0.request.identifier == identifier }.count
    if remaining == 0 || Date() >= deadline {
      finish(remaining)
    } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { verifyRemoval() }
    }
  }
}

center.getDeliveredNotifications { notifications in
  let matchingIdentifier = notifications.filter { $0.request.identifier == identifier }
  guard matchingIdentifier.allSatisfy({
    $0.request.content.userInfo["requestId"] as? String == requestId
  }) else {
    fputs("Synthetic request identity mismatch; nothing removed\n", stderr)
    exit(1)
  }
  originalMatches = matchingIdentifier.count
  center.removeDeliveredNotifications(withIdentifiers: [identifier])
  verifyRemoval()
}
DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
  fputs("Synthetic notification cleanup observation timed out\n", stderr)
  exit(1)
}
application.run()
