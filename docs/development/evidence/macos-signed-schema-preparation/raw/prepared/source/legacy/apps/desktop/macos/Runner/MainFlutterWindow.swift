import Cocoa
import Security
import FlutterMacOS
import UserNotifications

class MainFlutterWindow: NSWindow, NSWindowDelegate, UNUserNotificationCenterDelegate {
  private var desktopChannel: FlutterMethodChannel?
  private var statusItem: NSStatusItem?
  private(set) var desktopReady = false
  private var notificationsEnabled = false
  private var backupOutputs: [String: URL] = [:]
  private var backupStaging: [String: URL] = [:]
  private var informationOutputs: [String: URL] = [:]
  private var informationStaging: [String: URL] = [:]
  private var toolAccess: ToolAccessStore?
  private var choosingToolDirectory = false

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.title = "信息授权"

    RegisterGeneratedPlugins(registry: flutterViewController)
    configureToolAccess(flutterViewController)

    // Local, owner-process-only bridge; never exposed by the Agent HTTP server.
    let keyChannel = FlutterMethodChannel(name: "agent_info_manage/database_key", binaryMessenger: flutterViewController.engine.binaryMessenger)
    let databaseKeys = NativeDatabaseKeyStore(service: "org.shijijs.agent-info-manage.qa.schema.d12281f9-2a3a-4ca8-988e-d8c190e54f0f")
    let keyQueue = DispatchQueue(label: "agent_info_manage.database_key")
    keyChannel.setMethodCallHandler { call, result in
      // A legacy ACL/unlock dialog can wait indefinitely. Keep every key
      // operation (including lock contention) off the Cocoa/Flutter thread.
      keyQueue.async {
        let reply: FlutterResult = { value in
          DispatchQueue.main.async { result(value) }
        }
        do {
          if call.method == "qaDelete" {
            try mutateOwnedKeychainFixture(call.method)
            reply(nil)
          } else if call.method == "read" || call.method == "readWithInteraction" {
            if let data = try databaseKeys.read(allowInteraction: call.method == "readWithInteraction") {
              reply(FlutterStandardTypedData(bytes: data))
            } else {
              reply(nil)
            }
          } else if call.method == "create" {
            guard let data = call.arguments as? FlutterStandardTypedData else {
              throw DatabaseKeyFailure(code: "invalid_key", status: nil)
            }
            try databaseKeys.create(data.data)
            reply(nil)
          } else {
            reply(FlutterMethodNotImplemented)
          }
        } catch let failure as DatabaseKeyFailure {
          reply(FlutterError(code: failure.code, message: "System key unavailable", details: nil))
        } catch {
          reply(FlutterError(code: "key_unavailable", message: "System key unavailable", details: nil))
        }
      }
    }

    let backupFiles = FlutterMethodChannel(name: "agent_info_manage/backup_files", binaryMessenger: flutterViewController.engine.binaryMessenger)
    backupFiles.setMethodCallHandler { [weak self] call, result in
      guard let window = self else {
        result(FlutterError(code: "file_dialog_failed", message: "Window unavailable", details: nil)); return
      }
      if call.method == "prepareInformationStaging" {
        guard let path = call.arguments as? String, let destination = window.informationOutputs.removeValue(forKey: path) else {
          result(FlutterError(code: "file_export_failed", message: "No selected file destination", details: nil)); return
        }
        do {
          let directory = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
          let token = UUID().uuidString
          window.informationStaging[token] = directory
          result(["directory": directory.path, "token": token])
        } catch {
          result(FlutterError(code: "file_export_failed", message: "File staging unavailable", details: nil))
        }
      } else if call.method == "releaseInformationStaging" {
        guard let token = call.arguments as? String, let directory = window.informationStaging.removeValue(forKey: token) else {
          result(FlutterError(code: "file_export_failed", message: "Unknown file staging", details: nil)); return
        }
        do {
          if try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty {
            try FileManager.default.removeItem(at: directory)
          }
          result(nil)
        } catch {
          result(FlutterError(code: "file_export_failed", message: "File staging cleanup incomplete", details: nil))
        }
      } else if call.method == "prepareBackupStaging" {
        guard let path = call.arguments as? String, let destination = window.backupOutputs.removeValue(forKey: path) else {
          result(FlutterError(code: "backup_staging_failed", message: "No selected backup destination", details: nil)); return
        }
        do {
          let directory = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
          let token = UUID().uuidString
          window.backupStaging[token] = directory
          result(["directory": directory.path, "token": token])
        } catch {
          result(FlutterError(code: "backup_staging_failed", message: "Backup staging unavailable", details: nil))
        }
      } else if call.method == "releaseBackupStaging" {
        guard let token = call.arguments as? String, let directory = window.backupStaging.removeValue(forKey: token) else {
          result(FlutterError(code: "backup_staging_failed", message: "Unknown backup staging", details: nil)); return
        }
        // Only this native-created URL can be released; no arbitrary paths or
        // recursive deletion supplied by Dart. Failed cleanup preserves files.
        do {
          if try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty {
            try FileManager.default.removeItem(at: directory)
          }
          result(nil)
        } catch {
          result(FlutterError(code: "backup_staging_failed", message: "Backup staging cleanup incomplete", details: nil))
        }
      } else if call.method == "backupInput" || call.method == "recoveryKeyInput" || call.method == "credentialInput" || call.method == "knownHostsInput" || call.method == "informationFileInput" {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if call.method == "backupInput" || call.method == "recoveryKeyInput" { panel.allowedFileTypes = [call.method == "recoveryKeyInput" ? "txt" : "aimbackup"] }
        panel.beginSheetModal(for: window) { response in
          result(response == .OK ? panel.url?.path : nil)
        }
      } else if call.method == "informationFileOutput" {
        guard let name = call.arguments as? String, !name.isEmpty, name.utf8.count <= 4096 else {
          result(FlutterError(code: "file_dialog_failed", message: "Invalid file name", details: nil)); return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { response in
          if response == .OK, let url = panel.url { window.informationOutputs[url.path] = url }
          result(response == .OK ? panel.url?.path : nil)
        }
      } else if call.method == "backupOutput" || call.method == "recoveryKeyOutput" {
        let recovery = call.method == "recoveryKeyOutput"
        let panel = NSSavePanel()
        panel.allowedFileTypes = [recovery ? "txt" : "aimbackup"]
        panel.nameFieldStringValue = recovery ? "agent-info-recovery-key.txt" : "information-backup.aimbackup"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { response in
          if response == .OK, !recovery, let url = panel.url { window.backupOutputs[url.path] = url }
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
      case "notify", "testNotify":
        guard self.notificationsEnabled else { result(false); return }
        let content = UNMutableNotificationContent()
        content.title = "信息访问授权"
        content.body = call.method == "testNotify" ? "这是一条测试通知。访问申请提醒已连接到系统。" : "有新的访问请求。打开应用查看并审批。"
        if call.method == "notify", let requestId = call.arguments as? String {
          content.userInfo = ["requestId": requestId]
        }
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

  private func configureToolAccess(_ controller: FlutterViewController) {
    if let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
      toolAccess = ToolAccessStore(file: base.appendingPathComponent("AgentInfoManage/tool-access/directories.json"))
    }
    let channel = FlutterMethodChannel(name: "agent_info_manage/tool_directories",
                                       binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let window = self, let store = window.toolAccess else {
        result(FlutterError(code: "tool_access_storage_failed", message: "Tool directory settings unavailable", details: nil))
        return
      }
      if call.method == "read" {
        result(store.snapshot())
      } else if call.method == "forget", let id = call.arguments as? String {
        do {
          try store.forget(id)
          result(store.snapshot())
        } catch {
          result(FlutterError(code: "tool_access_storage_failed", message: "Directory was not removed", details: nil))
        }
      } else if call.method == "choose" {
        guard !window.choosingToolDirectory else {
          result(FlutterError(code: "tool_access_busy", message: "Directory chooser already open", details: nil))
          return
        }
        guard call.arguments == nil || call.arguments is String else {
          result(FlutterError(code: "tool_access_unknown", message: "Invalid directory reference", details: nil))
          return
        }
        let panel = NSOpenPanel()
        panel.title = "选择外部工具目录"
        panel.message = "选择 GH 或 AWS 的安装目录，包含程序及其依赖文件。"
        panel.prompt = "允许访问"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        window.choosingToolDirectory = true
        panel.beginSheetModal(for: window) { response in
          window.choosingToolDirectory = false
          window.showApprovalsWindow()
          guard response == .OK, let url = panel.url else { result(nil); return }
          do {
            try store.rememberSelection(url, replacing: call.arguments as? String)
            result(store.snapshot())
          } catch let error as ToolAccessFailure {
            result(FlutterError(code: error.code, message: "Directory access was not saved", details: nil))
          } catch {
            result(FlutterError(code: "tool_access_unavailable", message: "Directory access unavailable", details: nil))
          }
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
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
    DispatchQueue.main.async {
      self.showApprovalsWindow()
      self.desktopChannel?.invokeMethod("open", arguments: response.notification.request.content.userInfo["requestId"] as? String)
      completionHandler()
    }
  }
}

// QA COPY ONLY: macos-flutter-keychain.py appends this to an isolated source
// copy. It is never included in the production Xcode target. org.shijijs.agent-info-manage.qa.schema.d12281f9-2a3a-4ca8-988e-d8c190e54f0f is a
// fresh runner-owned UUID service; no caller-supplied service/account allowed.
private func mutateOwnedKeychainFixture(_ method: String) throws {
  var previous: DarwinBoolean = true
  guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
        SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
    throw DatabaseKeyFailure(code: "qa_interaction_failed", status: nil)
  }
  defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
  let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "org.shijijs.agent-info-manage.qa.schema.d12281f9-2a3a-4ca8-988e-d8c190e54f0f",
    kSecAttrAccount as String: NativeDatabaseKeyStore.account,
    kSecUseDataProtectionKeychain as String: false,
  ]
  let removed = SecItemDelete(query as CFDictionary)
  guard removed == errSecSuccess || removed == errSecItemNotFound else {
    throw DatabaseKeyFailure(code: "qa_delete_failed", status: removed)
  }
  if method != "qaDelete" {
    var insertion = query
    insertion[kSecValueData as String] = Data(repeating: 29, count: method == "qaMalformed" ? 31 : 32)
    let added = SecItemAdd(insertion as CFDictionary, nil)
    guard added == errSecSuccess else {
      throw DatabaseKeyFailure(code: "qa_insertion_failed", status: added)
    }
  }
}
