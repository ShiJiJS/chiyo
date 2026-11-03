import Cocoa
import FlutterMacOS

/// Embedded secure input for proposal passwords; no sheet or extra save action.
final class NativeInlinePasswordFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger
  init(messenger: FlutterBinaryMessenger) { self.messenger = messenger; super.init() }
  func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? { FlutterStandardMessageCodec.sharedInstance() }
  func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
    NativeInlinePassword(viewId: viewId, arguments: args, messenger: messenger)
  }
}

private final class NativeInlinePassword: NSView, NSTextFieldDelegate {
  private let secure = NSSecureTextField(string: "")
  private let visible = NSTextField(string: "")
  private var obscured = true
  private var field: NSTextField { obscured ? secure : visible }
  private let channel: FlutterMethodChannel
  private var limit: Int?
  private var accepted = ""
  init(viewId: Int64, arguments: Any?, messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "agent_info_manage/inline_password/\(viewId)", binaryMessenger: messenger)
    super.init(frame: .zero)
    for input in [secure, visible] {
      input.isBordered = false
      input.drawsBackground = false
      input.focusRingType = .none
      input.translatesAutoresizingMaskIntoConstraints = false
      input.delegate = self
      addSubview(input)
      NSLayoutConstraint.activate([
        input.leadingAnchor.constraint(equalTo: leadingAnchor),
        input.trailingAnchor.constraint(equalTo: trailingAnchor),
        input.centerYAnchor.constraint(equalTo: centerYAnchor),
      ])
    }
    update(arguments)
    channel.setMethodCallHandler { [weak self] call, reply in
      guard let self else { reply(nil); return }
      guard call.method == "update" else { reply(FlutterMethodNotImplemented); return }
      self.update(call.arguments)
      reply(nil)
    }
  }
  required init?(coder: NSCoder) { fatalError("Not used") }
  private func update(_ arguments: Any?) {
    guard let args = arguments as? [String: Any], let value = args["value"] as? String,
          let enabled = args["enabled"] as? Bool, let label = args["label"] as? String else { return }
    limit = args["maxLength"] as? Int
    let nextObscured = args["obscured"] as? Bool ?? true
    let wasEditing = field.currentEditor() != nil
    let selection = field.currentEditor()?.selectedRange
    if obscured != nextObscured {
      field.abortEditing()
      obscured = nextObscured
    }
    secure.isHidden = !obscured
    visible.isHidden = obscured
    if field.stringValue != value {
      field.stringValue = value
      field.currentEditor()?.string = value
    }
    accepted = value
    if obscured { visible.stringValue = "" }
    for input in [secure, visible] {
      input.isEnabled = enabled
      input.setAccessibilityLabel(label)
      input.font = NSFont.systemFont(ofSize: CGFloat(args["fontSize"] as? Double ?? 14))
      input.textColor = enabled ? .labelColor : .disabledControlTextColor
    }
    appearance = NSAppearance(named: args["dark"] as? Bool == true ? .darkAqua : .aqua)
    if wasEditing && enabled && field.currentEditor() == nil {
      window?.makeFirstResponder(field)
      if let selection { field.currentEditor()?.selectedRange = selection }
    }
  }
  func controlTextDidChange(_ notification: Notification) {
    let value = field.stringValue
    guard !value.contains("\0"), value.utf8.count <= 65536,
          limit == nil || limit! <= 0 || value.count <= limit! else {
      field.stringValue = accepted
      field.currentEditor()?.string = accepted
      NSSound.beep()
      return
    }
    accepted = value
    channel.invokeMethod("changed", arguments: value)
  }
  deinit {
    channel.setMethodCallHandler(nil)
    field.abortEditing()
    secure.stringValue = ""
    visible.stringValue = ""
    accepted = ""
  }
}

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
