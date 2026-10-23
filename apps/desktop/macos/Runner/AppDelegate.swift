import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate, NSMenuItemValidation {
  var allowTermination = false

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return !(authorizationWindow?.desktopReady ?? false)
  }

  private var authorizationWindow: MainFlutterWindow? {
    mainFlutterWindow as? MainFlutterWindow
  }

  @IBAction func openSettings(_ sender: Any?) {
    authorizationWindow?.openSettings()
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(openSettings(_:)) {
      return authorizationWindow?.canOpenSettings ?? false
    }
    return true
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if !allowTermination, authorizationWindow?.requestFullQuit() == true {
      return .terminateCancel
    }
    return .terminateNow
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    authorizationWindow?.openApprovals()
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
