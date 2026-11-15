import Darwin
import Foundation

/// A live authenticated anchor makes an idle XPC exit distinguishable from a
/// crash caused by another short-lived permission connection being invalidated.
@main
enum PermissionLifecycleProbe {
  private static var anchor: NSXPCConnection?
  private static var client: MacFocusPermissionClient?
  private static var completed = 0
  private static var detailsChecked = false
  private static var finished = false

  private static func finish(_ state: String) {
    guard !finished else { return }
    finished = true
    let result: [String: Any] = ["state": state, "rounds": completed,
                               "detailsChecked": detailsChecked,
                               "permissionPrompted": false, "inputAttempted": false]
    print(String(data: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    fflush(stdout)
    anchor?.invalidate()
    exit(state == "passed" ? 0 : 2)
  }

  private static func valid(_ data: Data) -> Bool {
    guard let value = MacFocusPermissionStatus.decode(data) else { return false }
    return ["ready", "permission_required"].contains(value.state)
  }

  private static func ping(_ completion: @escaping () -> Void) {
    guard let proxy = anchor?.remoteObjectProxyWithErrorHandler({ _ in
      DispatchQueue.main.async { finish("anchor_lost") }
    }) as? MacFocusPrivateProtocol else { finish("anchor_unavailable"); return }
    proxy.permissions { data in
      DispatchQueue.main.async {
        guard valid(data) else { finish("anchor_reply_invalid"); return }
        completion()
      }
    }
  }

  private static func next() {
    if completed == 3 {
      ping { finish("passed") }
      return
    }
    do {
      let current = try MacFocusPermissionClient()
      client = current
      if completed == 0 {
        current.permissionDetails { details in
          DispatchQueue.main.async {
            guard details.state == "checked", details.accessibilityTrusted != nil,
                  details.postEventsTrusted != nil else { finish("details_unavailable"); return }
            detailsChecked = true
            completeRound()
          }
        }
        return
      }
      current.query(prompt: false) { status in
        DispatchQueue.main.async {
          guard ["ready", "permission_required"].contains(status.state) else {
            finish("short_connection_unavailable"); return
          }
          completeRound()
        }
      }
    } catch { finish("initialization_failed") }
  }

  private static func completeRound() {
    completed += 1
    client = nil
    // Let invalidation reach the helper before the next independent query.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { next() }
  }

  static func main() {
    do {
      let connection = try MacFocusPrivateConnection.open()
      anchor = connection
      connection.invalidationHandler = { DispatchQueue.main.async { finish("anchor_lost") } }
      connection.interruptionHandler = { DispatchQueue.main.async { finish("anchor_interrupted") } }
      connection.resume()
      DispatchQueue.main.asyncAfter(deadline: .now() + 10) { finish("timeout") }
      ping { next() }
      RunLoop.main.run()
    } catch { finish("initialization_failed") }
  }
}
