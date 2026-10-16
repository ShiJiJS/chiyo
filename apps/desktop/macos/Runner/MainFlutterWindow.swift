import Cocoa
import FlutterMacOS
import Security
import UserNotifications

class MainFlutterWindow: NSWindow, NSWindowDelegate, UNUserNotificationCenterDelegate {
  private var desktopChannel: FlutterMethodChannel?
  private var statusItem: NSStatusItem?
  private(set) var desktopReady = false
  private var notificationsEnabled = false

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Local, owner-process-only bridge; never exposed by the Agent HTTP server.
    let keyChannel = FlutterMethodChannel(name: "agent_info_manage/database_key", binaryMessenger: flutterViewController.engine.binaryMessenger)
    keyChannel.setMethodCallHandler { call, result in
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "org.shijijs.agent-info-manage.database",
        kSecAttrAccount as String: "local-database-v1",
        kSecUseDataProtectionKeychain as String: false,
        kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
      ]
      if call.method == "read" {
        var readQuery = query
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var output: CFTypeRef?
        let status = SecItemCopyMatching(readQuery as CFDictionary, &output)
        if status == errSecItemNotFound { result(nil); return }
        guard status == errSecSuccess, let data = output as? Data, data.count == 32 else {
          result(FlutterError(code: "key_unavailable", message: "System key unavailable", details: nil)); return
        }
        result(FlutterStandardTypedData(bytes: data))
      } else if call.method == "create" {
        guard let data = call.arguments as? FlutterStandardTypedData, data.data.count == 32 else {
          result(FlutterError(code: "invalid_key", message: "Invalid key", details: nil)); return
        }
        var writeQuery = query
        writeQuery[kSecValueData as String] = data.data
        // SecItemAdd refuses duplicates; key failure never replaces an existing key.
        let status = SecItemAdd(writeQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
          result(FlutterError(code: "key_creation_failed", message: "System key creation failed", details: nil)); return
        }
        result(nil)
      } else { result(FlutterMethodNotImplemented) }
    }

    let backupFiles = FlutterMethodChannel(name: "agent_info_manage/backup_files", binaryMessenger: flutterViewController.engine.binaryMessenger)
    backupFiles.setMethodCallHandler { [weak self] call, result in
      guard let window = self else {
        result(FlutterError(code: "file_dialog_failed", message: "Window unavailable", details: nil)); return
      }
      if call.method == "backupInput" {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["aimbackup"]
        panel.beginSheetModal(for: window) { response in
          result(response == .OK ? panel.url?.path : nil)
        }
      } else if call.method == "backupOutput" || call.method == "recoveryKeyOutput" {
        let recovery = call.method == "recoveryKeyOutput"
        let panel = NSSavePanel()
        panel.allowedFileTypes = [recovery ? "txt" : "aimbackup"]
        panel.nameFieldStringValue = recovery ? "agent-info-recovery-key.txt" : "information-backup.aimbackup"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { response in
          result(response == .OK ? panel.url?.path : nil)
        }
      } else { result(FlutterMethodNotImplemented) }
    }

    let desktopChannel = FlutterMethodChannel(name: "agent_info_manage/desktop", binaryMessenger: flutterViewController.engine.binaryMessenger)
    self.desktopChannel = desktopChannel
    desktopChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      switch call.method {
      case "initialize":
        if !self.desktopReady {
          let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
          if let button = item.button {
            button.title = "信"
            button.toolTip = "信息访问授权"
            let menu = NSMenu()
            let open = NSMenuItem(title: "打开访问审批", action: #selector(self.openApprovals), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
            menu.addItem(NSMenuItem.separator())
            let quit = NSMenuItem(title: "完全退出", action: #selector(self.quitFromMenu), keyEquivalent: "")
            quit.target = self
            menu.addItem(quit)
            item.menu = menu
            self.statusItem = item
          } else { NSStatusBar.system.removeStatusItem(item) }
          self.desktopReady = true
          self.delegate = self
          UNUserNotificationCenter.current().delegate = self
        }
        self.readAvailability(result)
      case "availability": self.readAvailability(result)
      case "hide":
        let canHide = self.statusItem?.button != nil
        if canHide { self.orderOut(nil) }
        result(canHide)
      case "show":
        self.showApprovalsWindow()
        result(nil)
      case "enableNotifications":
        // The only call that may present the system permission prompt is made
        // after the user presses the explicit notification action in Flutter.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
          DispatchQueue.main.async { self.readAvailability(result) }
        }
      case "notify":
        guard self.notificationsEnabled else { result(false); return }
        let content = UNMutableNotificationContent()
        content.title = "信息访问授权"
        content.body = "有新的访问请求。打开应用查看并审批。"
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
          DispatchQueue.main.async { result(error == nil) }
        }
      case "terminate":
        if let item = self.statusItem { NSStatusBar.system.removeStatusItem(item) }
        self.statusItem = nil
        (NSApp.delegate as? AppDelegate)?.allowTermination = true
        result(nil)
        DispatchQueue.main.async { NSApp.terminate(nil) }
      default: result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }

  private func readAvailability(_ result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      let notificationState: String
      switch settings.authorizationStatus {
      case .authorized, .provisional: notificationState = "enabled"
      case .notDetermined: notificationState = "not_enabled"
      case .denied: notificationState = "denied"
      @unknown default: notificationState = "unavailable"
      }
      DispatchQueue.main.async {
        self.notificationsEnabled = notificationState == "enabled"
        result(["tray": self.statusItem?.button != nil, "notifications": notificationState])
      }
    }
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if !desktopReady { return true }
    desktopChannel?.invokeMethod("close", arguments: nil)
    return false
  }

  private func showApprovalsWindow() {
    deminiaturize(nil)
    makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc func openApprovals() {
    showApprovalsWindow()
    desktopChannel?.invokeMethod("open", arguments: nil)
  }

  @objc private func quitFromMenu() { _ = requestFullQuit() }
  func requestFullQuit() -> Bool {
    guard desktopReady else { return false }
    desktopChannel?.invokeMethod("quit", arguments: nil)
    return true
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter,
      willPresent notification: UNNotification,
      withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    completionHandler([.alert])
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter,
      didReceive response: UNNotificationResponse,
      withCompletionHandler completionHandler: @escaping () -> Void) {
    DispatchQueue.main.async { self.openApprovals(); completionHandler() }
  }
}
