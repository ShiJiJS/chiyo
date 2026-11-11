import Cocoa
import FlutterMacOS
import UserNotifications
import UniformTypeIdentifiers

class MainFlutterWindow: NSWindow, NSWindowDelegate, UNUserNotificationCenterDelegate {
  private var textEditingMenu: NativeTextEditingMenu?
  private var secretEditor: NativeSecretEditor?
  private var textFieldAccessibility: NativeTextFieldAccessibility?
  private var focusedFill: MacFocusedFillBridge?
  private var desktopChannel: FlutterMethodChannel?
  private var statusItem: NSStatusItem?
  private var statusItemVisibility: NSKeyValueObservation?
  private let pendingPopover = NSPopover()
  private var pendingState: [String: Any] = [:]
  private var pendingShowingProposals = false
  private var statusEntryAvailable: Bool {
    statusItem?.button != nil && statusItem?.isVisible == true
  }
  private(set) var desktopReady = false
  var keepsRunningWithoutWindow: Bool {
#if DEBUG
    if interfacePreview && statusItem != nil { return true }
#endif
    return desktopReady
  }
  private var previewReady = false
  // The built entry point, not a Dart runtime request, selects isolation before
  // any production service or saved security-scoped bookmark is constructed.
  private var interfacePreview: Bool {
    if Bundle.main.object(forInfoDictionaryKey: "AgentInfoInterfacePreview") as? String == "YES" {
      return true
    }
    let target = Bundle.main.object(forInfoDictionaryKey: "AgentInfoFlutterTarget") as? String ?? ""
    return ["preview_main.dart", "zhiyu_foundation_native_test.dart"].contains(
      URL(fileURLWithPath: target).lastPathComponent)
  }
  private var navigationEnabled = false
  private var notificationsEnabled = false
  private let backupStaging = BackupStagingRegistry()
  private let ownerFileOpener = OwnerFileOpener { NSWorkspace.shared.open($0) }
  private let pdfPreviewQueue = DispatchQueue(label: "agent_info_manage.owner_pdf_preview", qos: .userInitiated)
  private var renderingPdf = false
  private var informationOutputs: [String: URL] = [:]
  private var informationStaging: [String: URL] = [:]
  private var toolAccess: ToolAccessStore?
  private var choosingToolDirectory = false
  private var lifecycleObservers: [(NotificationCenter, NSObjectProtocol)] = []
  private var previewScrollbarObserver: NSObjectProtocol?
  private var previewScrollbarRevision = 0

  deinit {
    removeLifecycleObservers()
    if let observer = previewScrollbarObserver {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.title = "信息授权"

    RegisterGeneratedPlugins(registry: flutterViewController)
    let inlinePasswords = flutterViewController.registrar(forPlugin: "AgentInfoInlinePassword")
    inlinePasswords.register(NativeInlinePasswordFactory(messenger: inlinePasswords.messenger),
                             withId: "agent_info_manage/inline_password")
    if interfacePreview {
      configureInterfacePreview(flutterViewController)
      finishWindowSetup(flutterViewController)
      return
    }
    // The real three-column workspace needs a usable initial content area.
    // Clamp to the current display so smaller displays remain reachable.
    self.title = "知予"
    let visibleFrame = (screen ?? NSScreen.main)?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1280, height: 828)
    let available = contentRect(forFrameRect: visibleFrame).size
    contentMinSize = NSSize(width: min(1100, available.width), height: min(680, available.height))
    setContentSize(NSSize(width: min(1280, available.width), height: min(800, available.height)))
    center()
    configureToolAccess(flutterViewController)
    secretEditor = NativeSecretEditor(window: self, messenger: flutterViewController.engine.binaryMessenger)
    // Registers a local owner channel only. No helper/permission/AX work until
    // an explicit call, and Dart's Mac focused-fill capability remains disabled.
    focusedFill = MacFocusedFillBridge(messenger: flutterViewController.engine.binaryMessenger)
    textFieldAccessibility = NativeTextFieldAccessibility(view: flutterViewController.view)
    let accessibility = FlutterMethodChannel(name: "agent_info_manage/text_field_accessibility",
                                             binaryMessenger: flutterViewController.engine.binaryMessenger)
    accessibility.setMethodCallHandler { [weak self] call, result in
      guard call.method == "update" else { result(FlutterMethodNotImplemented); return }
      guard self?.textFieldAccessibility?.update(call.arguments) == true else {
        result(FlutterError(code: "invalid_accessibility_labels", message: "Invalid field labels", details: nil)); return
      }
      result(nil)
    }

    // Local, owner-process-only bridge; never exposed by the Agent HTTP server.
    let keyChannel = FlutterMethodChannel(name: "agent_info_manage/database_key", binaryMessenger: flutterViewController.engine.binaryMessenger)
    let databaseKeys = NativeDatabaseKeyStore()
    let keyQueue = DispatchQueue(label: "agent_info_manage.database_key")
    keyChannel.setMethodCallHandler { call, result in
      // A legacy ACL/unlock dialog can wait indefinitely. Keep every key
      // operation (including lock contention) off the Cocoa/Flutter thread.
      keyQueue.async {
        let reply: FlutterResult = { value in
          DispatchQueue.main.async { result(value) }
        }
        do {
          let scoped = ["readLocal", "readLocalWithInteraction", "createLocal"].contains(call.method)
          let arguments = call.arguments as? [String: Any]
          let keys: NativeDatabaseKeyStore
          if scoped {
            guard let id = arguments?["libraryId"] as? String,
                  id.range(of: "^[A-Za-z0-9_-]{32}$", options: .regularExpression) != nil else {
              throw DatabaseKeyFailure(code: "invalid_key", status: nil)
            }
            keys = NativeDatabaseKeyStore(account: "local-library-\(id)")
          } else { keys = databaseKeys }
          if ["read", "readWithInteraction", "readLocal", "readLocalWithInteraction"].contains(call.method) {
            let interactive = call.method == "readWithInteraction" || call.method == "readLocalWithInteraction"
            if let data = try keys.read(allowInteraction: interactive) {
              reply(FlutterStandardTypedData(bytes: data))
            } else {
              reply(nil)
            }
          } else if call.method == "create" || call.method == "createLocal" {
            guard let data = (scoped ? arguments?["key"] : call.arguments) as? FlutterStandardTypedData else {
              throw DatabaseKeyFailure(code: "invalid_key", status: nil)
            }
            try keys.create(data.data)
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

    let pdfPreviews = FlutterMethodChannel(name: "agent_info_manage/owner_pdf_preview", binaryMessenger: flutterViewController.engine.binaryMessenger)
    pdfPreviews.setMethodCallHandler { [weak self] call, reply in
      guard call.method == "renderPage" else { reply(FlutterMethodNotImplemented); return }
      guard let window = self else { reply(FlutterError(code: "preview_unavailable", message: "Window unavailable", details: nil)); return }
      guard let args = call.arguments as? [String: Any], args.count == 2,
            let bytes = args["bytes"] as? FlutterStandardTypedData,
            bytes.data.count > 0, bytes.data.count <= OwnerPdfPreview.byteLimit,
            let page = args["page"] as? Int, page >= 0 else {
        reply(FlutterError(code: "invalid_request", message: "Invalid PDF preview request", details: nil)); return
      }
      guard !window.renderingPdf else { reply(FlutterError(code: "preview_busy", message: "PDF preview busy", details: nil)); return }
      window.renderingPdf = true
      window.pdfPreviewQueue.async { [weak window] in
        let value: Any
        do {
          let rendered = try autoreleasepool { try OwnerPdfPreview.render(bytes.data, page: page) }
          value = ["png": FlutterStandardTypedData(bytes: rendered.png), "width": rendered.width,
                   "height": rendered.height, "page": rendered.page, "pageCount": rendered.pageCount]
        } catch let failure as OwnerPdfPreview.Failure {
          value = FlutterError(code: failure.code, message: "PDF preview unavailable", details: nil)
        } catch { value = FlutterError(code: "preview_unavailable", message: "PDF preview unavailable", details: nil) }
        DispatchQueue.main.async { window?.renderingPdf = false; reply(value) }
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
        guard let path = call.arguments as? String else {
          result(FlutterError(code: "backup_staging_failed", message: "No selected backup destination", details: nil)); return
        }
        do {
          result(try window.backupStaging.prepareSelected(path))
        } catch {
          result(FlutterError(code: "backup_staging_failed", message: "Backup staging unavailable", details: nil))
        }
      } else if call.method == "captureBackupOutputBookmark" {
        guard let token = call.arguments as? String else {
          result(FlutterError(code: "backup_access_required", message: "Invalid backup access", details: nil)); return
        }
        do { result(try window.backupStaging.outputBookmark(token)) }
        catch { result(FlutterError(code: "backup_access_required", message: "Original output access unavailable", details: nil)) }
      } else if call.method == "acquireBackupAccess" {
        guard let args = call.arguments as? [String: Any], let access = args["access"] as? [String: String],
              let needsOutput = args["needsOutput"] as? Bool else {
          result(FlutterError(code: "backup_access_required", message: "Invalid backup access", details: nil)); return
        }
        do { result(try window.backupStaging.acquireRecordedAccess(access, needsOutput: needsOutput)) }
        catch { result(FlutterError(code: "backup_access_required", message: "Original backup access unavailable", details: nil)) }
      } else if call.method == "releaseBackupAccess" {
        guard let token = call.arguments as? String else {
          result(FlutterError(code: "backup_access_required", message: "Invalid backup access", details: nil)); return
        }
        window.backupStaging.releaseAccess(token); result(nil)
      } else if call.method == "reselectBackupOutput" {
        guard let expected = call.arguments as? String, expected.hasPrefix("/") else {
          result(FlutterError(code: "backup_access_required", message: "Invalid original output", details: nil)); return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "请选择上次保存的原文件，仅用于核对原操作结果；不会再次导出或覆盖文件。"
        panel.prompt = "核对原文件"
        panel.beginSheetModal(for: window) { response in
          guard response == .OK, let url = panel.url else { result(nil); return }
          do { result(try window.backupStaging.reselectedOutputBookmark(url, expectedPath: expected)) }
          catch { result(FlutterError(code: "backup_access_required", message: "Original output selection unavailable", details: nil)) }
        }
      } else if call.method == "releaseRegisteredBackupStaging" {
        guard let value = call.arguments as? [String: String] else {
          result(FlutterError(code: "backup_staging_failed", message: "Invalid registered staging", details: nil)); return
        }
        do { try window.backupStaging.releaseRecorded(value); result(nil) }
        catch { result(FlutterError(code: "backup_staging_failed", message: "Registered staging cleanup incomplete", details: nil)) }
      } else if call.method == "releaseBackupStaging" {
        guard let token = call.arguments as? String else {
          result(FlutterError(code: "backup_staging_failed", message: "Unknown backup staging", details: nil)); return
        }
        do {
          try window.backupStaging.release(token)
          result(nil)
        } catch {
          // Failed/nonempty cleanup keeps native ownership and remains retryable.
          result(FlutterError(code: "backup_staging_failed", message: "Backup staging cleanup incomplete", details: nil))
        }
      } else if call.method == "backupInput" || call.method == "recoveryKeyInput" || call.method == "credentialInput" || call.method == "knownHostsInput" || call.method == "informationFileInput" || call.method == "templatePackageInput" {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if call.method == "templatePackageInput" {
          panel.title = "选择模板插件包"
          panel.allowedContentTypes = [.json]
        }
        if call.method == "backupInput" || call.method == "recoveryKeyInput" { panel.allowedFileTypes = [call.method == "recoveryKeyInput" ? "txt" : "aimbackup"] }
        panel.beginSheetModal(for: window) { response in
          guard response == .OK, let url = panel.url else { result(nil); return }
          if call.method == "backupInput" || call.method == "recoveryKeyInput" {
            do { result(try window.backupStaging.inputPath(url)) }
            catch { result(FlutterError(code: "file_dialog_failed", message: "Selected backup file unavailable", details: nil)) }
          } else { result(url.path) }
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
      } else if call.method == "ownerFileOutput" {
        guard let name = call.arguments as? String, !name.isEmpty, name.utf8.count <= 4096 else {
          result(FlutterError(code: "file_dialog_failed", message: "Invalid file name", details: nil)); return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { response in
          guard response == .OK, let url = panel.url else { result(nil); return }
          do { result(try window.backupStaging.selectOutput(url, recovery: false)) }
          catch { result(FlutterError(code: "file_dialog_failed", message: "Selected destination unavailable", details: nil)) }
        }
      } else if call.method == "backupOutput" || call.method == "recoveryKeyOutput" {
        let recovery = call.method == "recoveryKeyOutput"
        let panel = NSSavePanel()
        panel.allowedFileTypes = [recovery ? "txt" : "aimbackup"]
        panel.nameFieldStringValue = recovery ? "agent-info-recovery-key.txt" : "information-backup.aimbackup"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { response in
          guard response == .OK, let url = panel.url else { result(nil); return }
          do { result(try window.backupStaging.selectOutput(url, recovery: recovery)) }
          catch { result(FlutterError(code: "file_dialog_failed", message: "Selected backup destination unavailable", details: nil)) }
        }
      } else { result(FlutterMethodNotImplemented) }
    }

    let fileOpenChannel = FlutterMethodChannel(name: "agent_info_manage/owner_file_open", binaryMessenger: flutterViewController.engine.binaryMessenger)
    fileOpenChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(FlutterError(code: "file_open_unavailable", message: "File open unavailable", details: nil)); return }
      do {
        if call.method == "open", let value = call.arguments as? [String: Any] {
          result(try self.ownerFileOpener.open(value).rawValue)
        } else if call.method == "status", let value = call.arguments as? [String: String], value.count == 2,
          let id = value["operationId"], let digest = value["commandDigest"] {
          result(try self.ownerFileOpener.status(id, digest: digest)?.rawValue)
        } else { result(FlutterMethodNotImplemented) }
      } catch OwnerFileOpener.Failure.invalid {
        result("notOpened")
      } catch OwnerFileOpener.Failure.busy {
        result("notOpened")
      } catch OwnerFileOpener.Failure.changed {
        result("notOpened")
      } catch {
        result(FlutterError(code: "file_open_unavailable", message: "File open unavailable", details: nil))
      }
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
            self.statusItemVisibility = item.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
              DispatchQueue.main.async { [weak self] in
                guard let self, self.desktopReady else { return }
                // A retained button does not mean the status item is usable.
                // Restore the window before announcing a lost background entry.
                if !self.statusEntryAvailable && (!self.isVisible || self.isMiniaturized) {
                  self.showApprovalsWindow()
                }
                self.desktopChannel?.invokeMethod("availability", arguments: nil)
              }
            }
          } else { NSStatusBar.system.removeStatusItem(item) }
          self.desktopReady = true
          self.delegate = self
          UNUserNotificationCenter.current().delegate = self
          self.observeDesktopLifecycle()
        }
        self.readAvailability(result)
      case "updatePendingMenu":
        if let state = call.arguments as? [String: Any] { self.updatePendingMenu(state) }
        result(nil)
      case "availability": self.readAvailability(result)
      case "setNavigationEnabled":
        guard let enabled = call.arguments as? Bool else {
          result(FlutterError(code: "invalid_navigation_state", message: "Invalid navigation state", details: nil)); return
        }
        self.navigationEnabled = enabled && self.desktopReady
        result(nil)
      case "hide":
        let canHide = self.statusEntryAvailable
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
        // add() can accept a request after system notifications were disabled.
        // Refresh the actual permission instead of trusting the startup cache.
        self.readAvailability { _ in
          guard self.desktopReady && self.notificationsEnabled else { result(false); return }
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
        }
      case "terminate":
        self.focusedFill?.close()
        self.textFieldAccessibility?.update([] as [[String: Any]])
        self.desktopReady = false
        self.navigationEnabled = false
        self.removeLifecycleObservers()
        self.pendingPopover.performClose(nil)
        self.pendingPopover.contentViewController = nil
        self.pendingState.removeAll()
        self.statusItemVisibility?.invalidate()
        self.statusItemVisibility = nil
        if let item = self.statusItem { NSStatusBar.system.removeStatusItem(item) }
        self.statusItem = nil
        (NSApp.delegate as? AppDelegate)?.allowTermination = true
        result(nil)
        DispatchQueue.main.async { NSApp.terminate(nil) }
      default: result(FlutterMethodNotImplemented)
      }
    }

    finishWindowSetup(flutterViewController)
  }

  private func configureInterfacePreview(_ controller: FlutterViewController) {
    title = "知予 · 界面预览·示例数据"
    delegate = self
    // This is an in-process Cocoa editor, not a credential/data service. Keep
    // the same secure-input UI seam that the production forms already use.
    secretEditor = NativeSecretEditor(window: self, messenger: controller.engine.binaryMessenger)
    // Ordinary text editing/accessibility is shared with production. Secret
    // execution, directories, file panels, notifications and database channels
    // are deliberately absent from this runner mode.
    textFieldAccessibility = NativeTextFieldAccessibility(view: controller.view)
    let accessibility = FlutterMethodChannel(name: "agent_info_manage/text_field_accessibility",
                                             binaryMessenger: controller.engine.binaryMessenger)
    accessibility.setMethodCallHandler { [weak self] call, result in
      guard call.method == "update" else { result(FlutterMethodNotImplemented); return }
      guard self?.textFieldAccessibility?.update(call.arguments) == true else {
        result(FlutterError(code: "invalid_accessibility_labels", message: "Invalid field labels", details: nil)); return
      }
      result(nil)
    }
    let channel = FlutterMethodChannel(name: "agent_info_manage/interface_preview",
                                      binaryMessenger: controller.engine.binaryMessenger)
    desktopChannel = channel
    previewScrollbarObserver = NotificationCenter.default.addObserver(
      forName: NSScroller.preferredScrollerStyleDidChangeNotification,
      object: nil, queue: .main
    ) { [weak self] _ in
      guard let self, self.previewReady else { return }
      self.previewScrollbarRevision += 1
      self.desktopChannel?.invokeMethod("scrollbarStyleChanged", arguments: [
        "style": self.previewScrollbarStyle, "revision": self.previewScrollbarRevision
      ])
    }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(nil); return }
      switch call.method {
      case "initialize":
        guard Bundle.main.bundleIdentifier == "com.example.infoDesktop.zhiyuPreview" else {
          result(FlutterError(code: "preview_configuration_required", message: "Use scripts/dev-macos.sh preview or preview-check", details: nil)); return
        }
        self.previewReady = true
        self.navigationEnabled = true
        self.configurePreviewAppearance()
        result(["isolated": true, "title": self.title,
                "applicationId": Bundle.main.bundleIdentifier ?? "",
                "productionServices": self.desktopReady || self.focusedFill != nil,
                "savedDirectories": self.toolAccess != nil,
                "scrollbarStyle": self.previewScrollbarStyle,
                "scrollbarRevision": self.previewScrollbarRevision])
      case "setNavigationEnabled":
        guard let enabled = call.arguments as? Bool else {
          result(FlutterError(code: "invalid_navigation_state", message: "Invalid navigation state", details: nil)); return
        }
        self.navigationEnabled = enabled && self.previewReady
        result(nil)
#if DEBUG
      case "updatePendingMenu":
        guard self.previewReady, let state = call.arguments as? [String: Any] else {
          result(FlutterMethodNotImplemented); return
        }
        if self.statusItem == nil {
          self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
          self.statusItem?.menu = NSMenu()
        }
        self.updatePendingMenu(state)
        result(nil)
      case "testPendingMenu":
        guard self.previewReady, let options = call.arguments as? [String: Any] else {
          result(FlutterMethodNotImplemented); return
        }
        self.testPendingMenu(options, result)
#endif
      case "createEvidenceDirectory":
        do {
          let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ZhiyuUI-\(UUID().uuidString)")
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
          result(directory.path)
        } catch {
          result(FlutterError(code: "preview_evidence_failed", message: "Temporary evidence directory unavailable", details: nil))
        }
      case "activateMenu":
        let action: Selector
        switch call.arguments as? String {
        case "settings": action = #selector(AppDelegate.openSettings(_:))
        case "search": action = #selector(AppDelegate.searchApprovals(_:))
        default: result(FlutterMethodNotImplemented); return
        }
        guard let menu = NSApp.mainMenu, let item = self.findMenuItem(action, in: menu) else {
          result(false); return
        }
        item.menu?.update()
        guard item.isEnabled else { result(false); return }
        result(NSApp.sendAction(action, to: item.target, from: item))
      case "windowState":
        result(["active": NSApp.isActive, "keyWindow": self.isKeyWindow,
                "visible": self.isVisible, "miniaturized": self.isMiniaturized,
                "occluded": !self.occlusionState.contains(.visible),
                "onActiveSpace": self.isOnActiveSpace,
                "scrollbarStyle": self.previewScrollbarStyle,
                "scrollbarRevision": self.previewScrollbarRevision,
                "width": self.contentView?.bounds.width ?? 0,
                "height": self.contentView?.bounds.height ?? 0])
      case "setContentSize":
        guard let size = call.arguments as? [String: NSNumber],
              let width = size["width"]?.doubleValue,
              let height = size["height"]?.doubleValue,
              width.isFinite, height.isFinite,
              (600...1600).contains(width), (400...1000).contains(height) else {
          result(FlutterError(code: "invalid_preview_size", message: "Invalid preview content size", details: nil)); return
        }
        self.setContentSize(NSSize(width: width, height: height))
        result(nil)
      case "quit":
        result(nil)
        DispatchQueue.main.async { self.quitFromMenu() }
      case "close":
        result(nil)
        DispatchQueue.main.async { self.performClose(nil) }
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func finishWindowSetup(_ flutterViewController: FlutterViewController) {
    super.awakeFromNib()
    DispatchQueue.main.async { [weak self] in
      guard let self, let menu = NSApp.mainMenu else { return }
      self.routeQuitMenu(in: menu)
      let forwarding = NativeTextEditingMenu(window: self, messenger: flutterViewController.engine.binaryMessenger)
      forwarding.install(in: menu)
      self.textEditingMenu = forwarding
    }
  }

  func configurePreviewAppearance() {
    guard interfacePreview else { return }
    title = "知予 · 界面预览·示例数据"
    if let item = NSApp.mainMenu?.items.first {
      item.title = "知予"
      item.submenu?.title = "知予"
    }
  }

  private var previewScrollbarStyle: String {
    NSScroller.preferredScrollerStyle == .overlay ? "overlay" : "legacy"
  }

  private func findMenuItem(_ action: Selector, in menu: NSMenu) -> NSMenuItem? {
    for item in menu.items {
      if item.action == action { return item }
      if let submenu = item.submenu, let found = findMenuItem(action, in: submenu) { return found }
    }
    return nil
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
        result(["tray": self.statusEntryAvailable, "notifications": notificationState,
                "scrollbarStyle": NSScroller.preferredScrollerStyle == .overlay ? "overlay" : "legacy"])
      }
    }
  }

  private func observeDesktopLifecycle() {
    guard lifecycleObservers.isEmpty else { return }
    // Public workspace events also cover resuming while the app stays hidden.
    // Merely returning to the app refreshes permission changes made in Settings.
    let events: [(NotificationCenter, Notification.Name, String)] = [
      (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification, "resume"),
      (NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification, "resume"),
      (NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidBecomeActiveNotification, "resume"),
      (NotificationCenter.default, NSApplication.didBecomeActiveNotification, "availability"),
      (NotificationCenter.default, NSScroller.preferredScrollerStyleDidChangeNotification, "availability"),
    ]
    for (center, name, method) in events {
      let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        guard let self, self.desktopReady else { return }
        self.desktopChannel?.invokeMethod(method, arguments: nil)
      }
      lifecycleObservers.append((center, observer))
    }
  }

  private func removeLifecycleObservers() {
    for (center, observer) in lifecycleObservers { center.removeObserver(observer) }
    lifecycleObservers.removeAll()
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    secretEditor?.cancel()
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
        // The owner chooses the range before opening the OS panel. No path
        // supplied by Flutter or an Agent can grant access.
        guard let arguments = call.arguments as? [String: Any],
              Set(arguments.keys).isSubset(of: ["permission", "replacing"]),
              let value = arguments["permission"] as? String,
              let permission = ToolDirectoryPermission(rawValue: value),
              arguments["replacing"] == nil || arguments["replacing"] is String else {
          result(FlutterError(code: "tool_access_unknown", message: "Invalid directory reference", details: nil))
          return
        }
        let panel = NSOpenPanel()
        let replacing = arguments["replacing"] as? String
        panel.title = permission == .readWrite ? "选择工作目录（读写）" : "选择外部目录（读取）"
        panel.message = permission == .readWrite
          ? "保存所选目录及其文件的读取与写入访问，重开应用后恢复。工具可在其中创建、修改或删除文件；使用凭据仍需另外批准。"
          : "保存所选目录的读取访问，重开应用后恢复。macOS 本次选择可能临时允许写入；保存的读取范围在重开后生效。目录选择不授予程序执行权限。"
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
            try store.rememberSelection(url, replacing: replacing, permission: permission)
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

#if DEBUG
  /// Native integration tests drive the same NSButtons and scroll view as the
  /// production popover, inside the isolated preview bundle.
  private func testPendingMenu(_ options: [String: Any], _ result: FlutterResult) {
    switch options["action"] as? String {
    case "show":
      if !pendingPopover.isShown { togglePendingPopover(nil) }
      result(pendingPopover.isShown)
    case "hideWindow":
      orderOut(nil)
      result(!isVisible)
    case "showWindow":
      showApprovalsWindow()
      result(isVisible)
    case "reset":
      pendingPopover.performClose(nil)
      pendingPopover.contentViewController = nil
      if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
      statusItem = nil
      pendingState.removeAll()
      result(nil)
    case "bottom":
      guard let view = pendingPopover.contentViewController?.view as? NSScrollView else {
        result(false); return
      }
      view.contentView.scroll(to: .zero)
      view.reflectScrolledClipView(view.contentView)
      result(true)
    case "capture":
      guard pendingPopover.isShown,
            let view = pendingPopover.contentViewController?.view as? NSScrollView,
            let document = view.documentView,
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        result(nil); return
      }
      view.cacheDisplay(in: view.bounds, to: bitmap)
      guard let png = bitmap.representation(using: .png, properties: [:]) else { result(nil); return }
      result(["png": FlutterStandardTypedData(bytes: png),
              "visibleHeight": view.documentVisibleRect.height,
              "documentHeight": document.bounds.height,
              "topInset": document.bounds.maxY - view.documentVisibleRect.maxY,
              "bottomInset": view.documentVisibleRect.minY - document.bounds.minY])
    case "activate":
      guard pendingPopover.isShown, let title = options["title"] as? String,
            let root = pendingPopover.contentViewController?.view else { result(false); return }
      func findButton(_ view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title && button.isEnabled { return button }
        return view.subviews.lazy.compactMap(findButton).first
      }
      guard let button = findButton(root), let action = button.action else { result(false); return }
      result(NSApp.sendAction(action, to: button.target, from: button))
    default: result(FlutterMethodNotImplemented)
    }
  }
#endif

  @objc private func togglePendingPopover(_ sender: Any?) {
    guard let button = statusItem?.button else { return }
    if pendingPopover.isShown { pendingPopover.performClose(nil); return }
    rebuildPendingPopover()
    NSApp.activate(ignoringOtherApps: true)
    pendingPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    pendingPopover.contentViewController?.view.window?.makeKey()
    desktopChannel?.invokeMethod("pendingMenuRefresh", arguments: nil)
  }

  private func rebuildPendingPopover() {
    // Colors come from Flutter's UiPalette, including the selected dark theme.
    func color(_ key: String, _ fallback: UInt32) -> NSColor {
      let value = pendingColors[key]?.uint32Value ?? fallback
      return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                     green: CGFloat((value >> 8) & 255) / 255,
                     blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    let accent = color("accent", 0x66528e), ink = color("ink", 0x242936)
    let muted = color("muted", 0x586477), paper = color("paper", 0xffffff)
    let rail = color("rail", 0xf7f8fa), line = color("line", 0xdce1e8)
    let onAccent = color("onAccent", 0xffffff)
    func label(_ value: String, size: CGFloat = 13, strong: Bool = false) -> NSTextField {
      let text = NSTextField(wrappingLabelWithString: value)
      text.font = .systemFont(ofSize: size, weight: strong ? .semibold : .regular)
      text.textColor = strong ? ink : muted
      text.preferredMaxLayoutWidth = 332
      return text
    }
    func button(_ title: String, action: Selector, primary: Bool = false) -> NSButton {
      let button = NSButton(title: title, target: self, action: action)
      button.isBordered = false; button.wantsLayer = true
      button.layer?.cornerRadius = 7
      button.layer?.backgroundColor = (primary ? accent : paper).cgColor
      button.layer?.borderWidth = primary ? 0 : 1
      button.layer?.borderColor = line.cgColor
      let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
      button.attributedTitle = NSAttributedString(string: title, attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: primary ? onAccent : ink, .paragraphStyle: paragraph,
      ])
      button.heightAnchor.constraint(equalToConstant: 32).isActive = true
      button.widthAnchor.constraint(equalToConstant: max(64, CGFloat(title.count * 14 + 24))).isActive = true
      return button
    }
    let installed = pendingPopover.contentViewController
    let controller = installed ?? NSViewController()
    let ready = pendingState["ready"] as? Bool == true
    let dark = pendingState["dark"] as? Bool == true
    let presentation = pendingState["presentation"] as? Int ?? 0
    let content = NSStackView()
    content.orientation = .vertical; content.alignment = .leading; content.spacing = 16
    content.edgeInsets = NSEdgeInsets(top: 20, left: 18, bottom: 18, right: 18)
    content.wantsLayer = true; content.layer?.backgroundColor = rail.cgColor
    let header = NSStackView(); header.orientation = .horizontal; header.spacing = 10
    header.addArrangedSubview(label("知予", size: 20, strong: true))
    if ready {
      let count = label("待处理 \(pendingApprovalCount + pendingProposalCount)", size: 13)
      count.textColor = accent; header.addArrangedSubview(count)
    }
    content.addArrangedSubview(header)
    content.addArrangedSubview(label(pendingState["location"] as? String ?? "未连接服务器", size: 12))
    let tabs = NSStackView(); tabs.orientation = .horizontal; tabs.spacing = 8
    let approvalTab = ready ? "访问审批 \(pendingApprovalCount)" : "访问审批"
    let proposalTab = ready ? "录入提案 \(pendingProposalCount)" : "录入提案"
    for (index, title) in [approvalTab, proposalTab].enumerated() {
      let tab = button(title, action: #selector(selectPendingCategory(_:)),
                       primary: (index == 1) == pendingShowingProposals)
      tab.tag = index
      tabs.addArrangedSubview(tab)
    }
    content.addArrangedSubview(tabs)
    let category = pendingShowingProposals ? "proposals" : "approvals"
    let rows = pendingShowingProposals ? pendingProposals : pendingRequests
    if ready && rows.isEmpty {
      content.addArrangedSubview(label(pendingShowingProposals ? "暂无待处理录入提案" : "暂无待处理访问申请"))
    }
    if let notice = pendingState["notice"] as? String, !notice.isEmpty {
      content.addArrangedSubview(label(notice))
    }
    if pendingState["checkResult"] as? Bool == true {
      let check = button("核对结果", action: #selector(checkPendingResult(_:)))
      check.tag = presentation
      content.addArrangedSubview(check)
    }
    for row in rows.prefix(3) {
      let card = NSStackView(); card.orientation = .vertical; card.alignment = .leading; card.spacing = 8
      card.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
      card.wantsLayer = true; card.layer?.cornerRadius = 8
      card.layer?.backgroundColor = paper.cgColor
      card.layer?.borderWidth = 1; card.layer?.borderColor = line.cgColor
      for (key, size, strong) in [("title", CGFloat(15), true), ("agent", CGFloat(12), false), ("purpose", CGFloat(13), false), ("scope", CGFloat(12), false)] {
        guard let value = row[key] as? String, !value.isEmpty else { continue }
        let text = label(value, size: size, strong: strong)
        // Do not clip the scope of an action that can be approved here.
        text.maximumNumberOfLines = 0
        card.addArrangedSubview(text)
        text.widthAnchor.constraint(equalToConstant: 332).isActive = true
      }
      let actions = NSStackView(); actions.orientation = .horizontal; actions.spacing = 8
      if !pendingShowingProposals && row["quick"] as? Bool == true {
        card.addArrangedSubview(label(row["duration"] as? String ?? "", size: 12))
        for (title, action) in [("批准", "approve"), ("拒绝", "deny")] {
          let control = button(title, action: #selector(pendingDecision(_:)), primary: action == "approve")
          control.identifier = NSUserInterfaceItemIdentifier("\(row["id"] as? String ?? "")|\(action)")
          control.tag = presentation
          actions.addArrangedSubview(control)
        }
      }
      let detail = button(pendingShowingProposals ? "查看提案" : "查看申请", action: #selector(openPendingRequest(_:)))
      let id = row["id"] as? String ?? ""
      detail.identifier = NSUserInterfaceItemIdentifier("\(category)|\(id)")
      detail.tag = presentation
      actions.addArrangedSubview(detail)
      card.addArrangedSubview(actions); content.addArrangedSubview(card)
      card.widthAnchor.constraint(equalToConstant: 360).isActive = true
    }
    let footer = NSStackView(); footer.orientation = .horizontal; footer.spacing = 8
    if ready {
      let all = button(pendingShowingProposals ? "查看全部录入提案" : "查看全部访问申请", action: #selector(openPendingRequest(_:)))
      all.tag = presentation
      all.identifier = NSUserInterfaceItemIdentifier(category)
      footer.addArrangedSubview(all)
    } else {
      footer.addArrangedSubview(button("打开知予", action: #selector(openPendingWorkspace(_:))))
    }
    footer.addArrangedSubview(button("完全退出", action: #selector(quitPendingMenu(_:))))
    content.addArrangedSubview(footer)
    content.widthAnchor.constraint(equalToConstant: 396).isActive = true
    content.layoutSubtreeIfNeeded()
    let scroll = (installed?.view as? NSScrollView) ?? NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
    scroll.drawsBackground = true; scroll.backgroundColor = rail
    scroll.documentView = content
    let screenHeight = statusItem?.button?.window?.screen?.visibleFrame.height ?? 800
    let height = min(680, max(150, screenHeight - 24), content.fittingSize.height)
    content.setFrameSize(NSSize(width: 396, height: content.fittingSize.height))
    scroll.frame = NSRect(x: 0, y: 0, width: 396, height: height)
    scroll.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    if installed == nil {
      controller.view = scroll
      pendingPopover.contentViewController = controller
    }
    pendingPopover.contentSize = NSSize(width: 396, height: height)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, content.frame.height - height)))
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  @objc private func selectPendingCategory(_ sender: NSButton) {
    pendingShowingProposals = sender.tag == 1
    rebuildPendingPopover()
  }

  private var pendingApprovalCount: Int { pendingState["approvalCount"] as? Int ?? 0 }
  private var pendingProposalCount: Int { pendingState["proposalCount"] as? Int ?? 0 }
  private var pendingRequests: [[String: Any]] { pendingState["requests"] as? [[String: Any]] ?? [] }
  private var pendingProposals: [[String: Any]] { pendingState["proposals"] as? [[String: Any]] ?? [] }
  private var pendingColors: [String: NSNumber] { pendingState["colors"] as? [String: NSNumber] ?? [:] }

  private func updatePendingMenu(_ state: [String: Any]) {
    guard let button = statusItem?.button else { return }
    let changed = !(pendingState as NSDictionary).isEqual(to: state)
    pendingState = state
    if statusItem?.menu != nil {
      statusItem?.menu = nil
      statusItem?.length = NSStatusItem.variableLength
      button.title = ""
      button.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "知予待办")
      button.image?.isTemplate = true
      button.imagePosition = .imageLeading
      button.target = self
      button.action = #selector(togglePendingPopover(_:))
      pendingPopover.behavior = .transient
    }
    let total = pendingApprovalCount + pendingProposalCount
    button.title = total > 0 ? String(total) : ""
    button.toolTip = total > 0 ? "知予 · 待处理 \(total)" : "知予"
    if changed && pendingPopover.isShown { rebuildPendingPopover() }
  }

  @objc private func pendingDecision(_ sender: NSButton) {
    guard navigationEnabled, attachedSheet == nil, let raw = sender.identifier?.rawValue else { return }
    let parts = raw.split(separator: "|").map(String.init)
    guard parts.count == 2 else { return }
    sender.isEnabled = false
    desktopChannel?.invokeMethod("pendingMenuDecision", arguments: [
      "id": parts[0], "approve": parts[1] == "approve", "presentation": sender.tag
    ]) { [weak self] _ in
      if self?.pendingPopover.isShown == true { self?.rebuildPendingPopover() }
    }
  }

  @objc private func checkPendingResult(_ sender: NSButton) {
    guard navigationEnabled, attachedSheet == nil else { return }
    sender.isEnabled = false
    desktopChannel?.invokeMethod("pendingMenuCheck", arguments: ["presentation": sender.tag]) { [weak self] _ in
      if self?.pendingPopover.isShown == true { self?.rebuildPendingPopover() }
    }
  }

  @objc private func openPendingRequest(_ sender: NSButton) {
    guard navigationEnabled, attachedSheet == nil else { return }
    pendingPopover.performClose(nil)
    guard let route = sender.identifier?.rawValue.split(separator: "|", maxSplits: 1), !route.isEmpty else { return }
    var arguments: [String: Any] = ["category": String(route[0]), "presentation": sender.tag]
    if route.count == 2 { arguments["id"] = String(route[1]) }
    desktopChannel?.invokeMethod("pendingMenuOpen", arguments: arguments)
  }

  @objc private func openPendingWorkspace(_ sender: NSButton) {
    pendingPopover.performClose(nil)
    showApprovalsWindow()
  }

  @objc private func quitPendingMenu(_ sender: NSButton) {
    pendingPopover.performClose(nil)
    quitFromMenu()
  }

  private func showApprovalsWindow() {
    deminiaturize(nil)
    makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc func openApprovals() {
    showApprovalsWindow()
    if previewReady { return }
    desktopChannel?.invokeMethod("open", arguments: nil)
  }

  var canOpenSettings: Bool { (desktopReady || previewReady) && navigationEnabled && attachedSheet == nil }

  func openSettings() {
    guard canOpenSettings else { return }
    showApprovalsWindow()
    desktopChannel?.invokeMethod("openSettings", arguments: nil)
  }

  func searchApprovals() {
    guard canOpenSettings else { return }
    showApprovalsWindow()
    desktopChannel?.invokeMethod("searchApprovals", arguments: nil)
  }

  private func routeQuitMenu(in menu: NSMenu) {
    for item in menu.items {
      if let submenu = item.submenu { routeQuitMenu(in: submenu) }
      if item.action == #selector(NSApplication.terminate(_:)) {
        item.target = self
        item.action = #selector(quitFromMenu)
      }
    }
  }

  @objc private func quitFromMenu() {
    if !requestFullQuit() {
      DispatchQueue.main.async { NSApp.terminate(nil) }
    }
  }
  func requestFullQuit() -> Bool {
    secretEditor?.cancel()
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
