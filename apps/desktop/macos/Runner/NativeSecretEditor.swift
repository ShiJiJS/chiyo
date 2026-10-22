import Cocoa
import FlutterMacOS

/// Owner-process UI only. No Agent endpoint, persistence or diagnostic output.
final class NativeSecretEditor {
  private weak var window: NSWindow?
  private let channel: FlutterMethodChannel
  private var active: Draft?
  private var closeObserver: NSObjectProtocol?

  private final class Draft: NSObject, NSTextFieldDelegate {
    let id: String
    let alert: NSAlert
    let field: NSSecureTextField
    let error: NSTextField
    let limit: Int?
    let reply: FlutterResult
    init(id: String, initial: String, title: String, limit: Int?, reply: @escaping FlutterResult) {
      self.id = id; self.limit = limit; self.reply = reply
      alert = NSAlert()
      alert.messageText = "编辑\(title)"
      alert.informativeText = "完成后更新当前表单，保存凭据后生效。"
      alert.addButton(withTitle: "完成")
      alert.addButton(withTitle: "取消")
      alert.buttons[0].keyEquivalent = "\r"
      alert.buttons[0].keyEquivalentModifierMask = []
      alert.buttons[1].keyEquivalent = "\u{1b}"
      alert.buttons[1].keyEquivalentModifierMask = []
      field = NSSecureTextField(string: initial)
      field.frame = NSRect(x: 0, y: 48, width: 440, height: 30)
      field.setAccessibilityLabel(title)
      error = NSTextField(wrappingLabelWithString: "")
      error.frame = NSRect(x: 0, y: 0, width: 440, height: 40)
      error.textColor = .systemRed
      let view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 84))
      view.addSubview(field); view.addSubview(error)
      alert.accessoryView = view
      alert.window.initialFirstResponder = field
      super.init()
      field.delegate = self
      validate()
    }
    var valid: Bool {
      let text = field.stringValue
      return !text.contains("\0") && text.utf8.count <= 65536 &&
        (limit == nil || text.count <= limit!)
    }
    func validate() {
      error.stringValue = valid ? "" : "内容过长或包含不支持的字符，请修改后再完成。"
      alert.buttons[0].isEnabled = valid
    }
    func controlTextDidChange(_ notification: Notification) { validate() }
    func clear() {
      field.currentEditor()?.string = ""
      field.stringValue = ""
    }
  }

  init(window: NSWindow, messenger: FlutterBinaryMessenger) {
    self.window = window
    channel = FlutterMethodChannel(name: "agent_info_manage/secret_editor", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, reply in
      guard let self else { reply(FlutterError(code: "unavailable", message: "Editor unavailable", details: nil)); return }
      if call.method == "cancel" {
        if let args = call.arguments as? [String: Any], let id = args["requestId"] as? String,
           self.active?.id == id { self.cancel() }
        reply(nil)
      } else if call.method == "edit" {
        self.edit(call.arguments, reply: reply)
      } else { reply(FlutterMethodNotImplemented) }
    }
    closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
      object: window, queue: .main) { [weak self] _ in self?.cancel() }
  }

  deinit {
    channel.setMethodCallHandler(nil)
    if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    active?.clear()
  }

  private func edit(_ arguments: Any?, reply: @escaping FlutterResult) {
    guard let window else { reply(FlutterError(code: "unavailable", message: "Editor unavailable", details: nil)); return }
    guard active == nil, window.attachedSheet == nil else {
      reply(FlutterError(code: "busy", message: "Another editor is open", details: nil)); return
    }
    guard let args = arguments as? [String: Any], let id = args["requestId"] as? String,
          let initial = args["initial"] as? String, let title = args["title"] as? String,
          !id.isEmpty, id.utf8.count <= 128, title.count <= 120 else {
      reply(FlutterError(code: "invalid_request", message: "Invalid editor request", details: nil)); return
    }
    let limit: Int?
    if let raw = args["maxLength"], !(raw is NSNull) {
      guard let number = raw as? Int, number == -1 || number > 0 else {
        reply(FlutterError(code: "invalid_request", message: "Invalid length limit", details: nil)); return
      }
      limit = number == -1 ? nil : number
    } else { limit = nil }
    let draft = Draft(id: id, initial: initial, title: title, limit: limit, reply: reply)
    active = draft
    draft.alert.beginSheetModal(for: window) { [weak self, weak draft] response in
      guard let self, let draft, self.active === draft else { return }
      self.active = nil
      let accepted = response == .alertFirstButtonReturn
      let value = accepted && draft.valid ? draft.field.stringValue : nil
      draft.clear()
      if accepted && value == nil {
        draft.reply(FlutterError(code: "invalid_value", message: "Invalid content", details: nil))
      } else { draft.reply(value) }
    }
    DispatchQueue.main.async { [weak self, weak draft] in
      guard let self, let draft, self.active === draft else { return }
      draft.alert.window.makeFirstResponder(draft.field)
    }
  }

  func cancel() {
    guard let draft = active, let window, window.attachedSheet === draft.alert.window else { return }
    window.endSheet(draft.alert.window, returnCode: .cancel)
  }
}
