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
  private var statusEntryAvailable: Bool {
    statusItem?.button != nil && statusItem?.isVisible == true
  }
  private(set) var desktopReady = false
  private var previewReady = false
  private let previewPopover = NSPopover()
  private var previewRequests: [[String: Any]] = []
  private var previewRequestCount = 0
  private var previewProposals: [[String: Any]] = []
  private var previewProposalCount = 0
  private var previewShowingProposals = false
  private var previewStorage = "已连接 · 家庭 NAS"
  private var previewColors: [String: NSNumber] = [:]

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
          if call.method == "read" || call.method == "readWithInteraction" {
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
    let available = (screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 1280, height: 820)
    contentMinSize = NSSize(width: min(1100, available.width), height: min(680, available.height - 40))
    setContentSize(NSSize(width: min(1280, available.width), height: min(800, available.height - 40)))
    center()
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
        self.installPreviewStatus()
        result(["isolated": true, "title": self.title,
                "applicationId": Bundle.main.bundleIdentifier ?? "",
                "productionServices": self.desktopReady || self.focusedFill != nil,
                "savedDirectories": self.toolAccess != nil,
                "scrollbarStyle": self.previewScrollbarStyle,
                "scrollbarRevision": self.previewScrollbarRevision])
      case "updatePreviewApprovals":
        guard let data = call.arguments as? [String: Any],
              let requests = data["requests"] as? [[String: Any]], let total = data["total"] as? Int else {
          result(FlutterError(code: "invalid_preview_requests", message: "Invalid preview requests", details: nil)); return
        }
        self.previewRequests = requests
        self.previewRequestCount = total
        self.previewProposals = data["proposals"] as? [[String: Any]] ?? []
        self.previewProposalCount = data["proposalTotal"] as? Int ?? 0
        self.previewStorage = data["storage"] as? String ?? ""
        self.previewColors = data["colors"] as? [String: NSNumber] ?? [:]
        let pending = total + self.previewProposalCount
        self.statusItem?.button?.title = pending > 0 ? " \(pending)" : ""
        self.rebuildPreviewPopover()
        result(nil)
      case "setNavigationEnabled":
        guard let enabled = call.arguments as? Bool else {
          result(FlutterError(code: "invalid_navigation_state", message: "Invalid navigation state", details: nil)); return
        }
        self.navigationEnabled = enabled && self.previewReady
        result(nil)
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

  // This panel exists only in the isolated UI runner. It projects the same
  // in-memory requests as Flutter; it cannot access the production server.
  private func installPreviewStatus() {
    guard statusItem == nil else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "知予原型待审批")
    item.button?.image?.isTemplate = true
    item.button?.target = self
    item.button?.action = #selector(togglePreviewPopover(_:))
    item.button?.toolTip = "知予原型 · 待审批"
    statusItem = item
    previewPopover.behavior = .transient
    rebuildPreviewPopover()
    if let menu = NSApp.mainMenu, !menu.items.contains(where: { $0.title == "原型状态" }) {
      let root = NSMenuItem(title: "原型状态", action: nil, keyEquivalent: "")
      let states = NSMenu(title: "原型状态")
      for (title, value) in [("连接断开页面", "offline")] {
        let row = NSMenuItem(title: title, action: #selector(previewConnectionState(_:)), keyEquivalent: "")
        row.target = self; row.representedObject = value; states.addItem(row)
      }
      let approvals = NSMenuItem(title: "打开菜单栏审批", action: #selector(togglePreviewPopover(_:)), keyEquivalent: "")
      approvals.target = self; states.addItem(approvals)
      root.submenu = states; menu.addItem(root)
    }
  }

  @objc private func previewConnectionState(_ sender: NSMenuItem) {
    guard navigationEnabled else { return }
    makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    desktopChannel?.invokeMethod("previewState", arguments: sender.representedObject)
  }

  @objc private func togglePreviewPopover(_ sender: Any?) {
    guard let button = statusItem?.button else { return }
    if previewPopover.isShown { previewPopover.performClose(nil); return }
    rebuildPreviewPopover()
    NSApp.activate(ignoringOtherApps: true)
    previewPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    previewPopover.contentViewController?.view.window?.makeKey()
  }

  private func rebuildPreviewPopover() {
    // Colors come from Flutter's UiPalette, including the selected dark theme.
    func color(_ key: String, _ fallback: UInt32) -> NSColor {
      let value = previewColors[key]?.uint32Value ?? fallback
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
    let controller = NSViewController()
    let content = NSStackView()
    content.orientation = .vertical; content.alignment = .leading; content.spacing = 16
    content.edgeInsets = NSEdgeInsets(top: 20, left: 18, bottom: 18, right: 18)
    content.wantsLayer = true; content.layer?.backgroundColor = rail.cgColor
    let header = NSStackView(); header.orientation = .horizontal; header.spacing = 10
    header.addArrangedSubview(label("知予", size: 20, strong: true))
    let count = label("待处理 \(previewRequestCount + previewProposalCount)", size: 13)
    count.textColor = accent; header.addArrangedSubview(count)
    content.addArrangedSubview(header)
    content.addArrangedSubview(label(previewStorage, size: 12))
    let tabs = NSStackView(); tabs.orientation = .horizontal; tabs.spacing = 8
    for (index, title) in ["访问审批 \(previewRequestCount)", "录入提案 \(previewProposalCount)"].enumerated() {
      let tab = button(title, action: #selector(selectPreviewCategory(_:)),
                       primary: (index == 1) == previewShowingProposals)
      tab.tag = index
      tabs.addArrangedSubview(tab)
    }
    content.addArrangedSubview(tabs)
    let rows = previewShowingProposals ? previewProposals : previewRequests
    if rows.isEmpty {
      content.addArrangedSubview(label(previewShowingProposals ? "暂无待处理录入提案" : "暂无待处理访问申请"))
    }
    for row in rows.prefix(3) {
      let card = NSStackView(); card.orientation = .vertical; card.alignment = .leading; card.spacing = 8
      card.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
      card.wantsLayer = true; card.layer?.cornerRadius = 8
      card.layer?.backgroundColor = paper.cgColor
      card.layer?.borderWidth = 1; card.layer?.borderColor = line.cgColor
      for (key, size, strong) in [("title", CGFloat(15), true), ("agent", CGFloat(12), false), ("purpose", CGFloat(13), false), ("scope", CGFloat(12), false)] {
        let text = label(row[key] as? String ?? "", size: size, strong: strong)
        // Do not clip the scope of an action that can be approved here.
        text.maximumNumberOfLines = 0
        card.addArrangedSubview(text)
        text.widthAnchor.constraint(equalToConstant: 332).isActive = true
      }
      let actions = NSStackView(); actions.orientation = .horizontal; actions.spacing = 8
      if !previewShowingProposals && row["quick"] as? Bool == true {
        card.addArrangedSubview(label("授权时长 · 2 小时", size: 12))
        for (title, action) in [("批准", "approve"), ("拒绝", "deny")] {
          let control = button(title, action: #selector(previewDecision(_:)), primary: action == "approve")
          control.identifier = NSUserInterfaceItemIdentifier("\(row["id"] as? String ?? "")|\(action)")
          actions.addArrangedSubview(control)
        }
      }
      let detail = button(previewShowingProposals ? "查看提案" : "查看申请", action: #selector(openPreviewRequest(_:)))
      detail.identifier = NSUserInterfaceItemIdentifier(row["id"] as? String ?? "")
      actions.addArrangedSubview(detail)
      card.addArrangedSubview(actions); content.addArrangedSubview(card)
      card.widthAnchor.constraint(equalToConstant: 360).isActive = true
    }
    content.addArrangedSubview(button(previewShowingProposals ? "查看全部录入提案" : "查看全部访问申请", action: #selector(openPreviewRequest(_:))))
    content.widthAnchor.constraint(equalToConstant: 396).isActive = true
    content.layoutSubtreeIfNeeded()
    let scroll = NSScrollView(); scroll.hasVerticalScroller = true
    scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
    scroll.drawsBackground = true; scroll.backgroundColor = rail
    scroll.documentView = content
    let height = min(680, content.fittingSize.height)
    content.setFrameSize(NSSize(width: 396, height: content.fittingSize.height))
    scroll.frame = NSRect(x: 0, y: 0, width: 396, height: height)
    controller.view = scroll; previewPopover.contentViewController = controller
    previewPopover.contentSize = NSSize(width: 396, height: height)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, content.frame.height - height)))
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  @objc private func selectPreviewCategory(_ sender: NSButton) {
    previewShowingProposals = sender.tag == 1
    rebuildPreviewPopover()
  }

  @objc private func previewDecision(_ sender: NSButton) {
    guard navigationEnabled, let raw = sender.identifier?.rawValue else { return }
    let parts = raw.split(separator: "|").map(String.init)
    guard parts.count == 2 else { return }
    sender.isEnabled = false
    desktopChannel?.invokeMethod("previewDecision", arguments: ["id": parts[0], "approve": parts[1] == "approve"]) { [weak self] _ in
      self?.rebuildPreviewPopover()
    }
  }

  @objc private func openPreviewRequest(_ sender: NSButton) {
    guard navigationEnabled else { return }
    previewPopover.performClose(nil)
    makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    if let id = sender.identifier?.rawValue, !id.isEmpty {
      desktopChannel?.invokeMethod(previewShowingProposals ? "previewProposal" : "previewRequest", arguments: id)
    } else { desktopChannel?.invokeMethod(previewShowingProposals ? "openProposals" : "open", arguments: nil) }
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
