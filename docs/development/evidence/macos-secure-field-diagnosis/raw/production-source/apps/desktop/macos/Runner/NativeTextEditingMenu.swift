import Cocoa
import FlutterMacOS

/// Accessibility's NSTextView can diverge from EditableText. Route editing
/// actions to Flutter, preserving AppKit behavior in native sheets.
final class NativeTextEditingMenu: NSObject, NSMenuItemValidation {
  private weak var window: NSWindow?
  private let methods = ["selectAll:": "selectAll", "copy:": "copy",
                         "cut:": "cut", "paste:": "paste",
                         "pasteAsPlainText:": "paste", "undo:": "undo", "redo:": "redo",
                         "delete:": "deleteSelection"]
  private let keyMethods = ["a": "selectAll", "c": "copy", "x": "cut", "v": "paste", "z": "undo"]
  private let channel: FlutterMethodChannel
  private var editingState: [String: Bool] = [:]
  private var menuGeneration = 0
  private var stateRequestPending = false
  private var menuObservers: [NSObjectProtocol] = []
  private var keyMonitor: Any?
  private var sheetObservers: [NSObjectProtocol] = []
  private var originalItems: [(item: NSMenuItem, target: AnyObject?, action: Selector, method: String)] = []

  init(window: NSWindow, messenger: FlutterBinaryMessenger) {
    self.window = window
    channel = FlutterMethodChannel(name: "agent_info_manage/text_editing", binaryMessenger: messenger)
    super.init()
  }

  deinit {
    restoreNativeActions()
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    for observer in sheetObservers + menuObservers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  func install(in menu: NSMenu) {
    guard keyMonitor == nil else { return }
    replaceEditingActions(in: menu)
    menuObservers = [
      NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
          object: nil, queue: .main) { [weak self] _ in
        self?.invalidateEditingState()
        self?.refreshEditingState()
      },
      NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification,
          object: nil, queue: .main) { [weak self] _ in
        self?.invalidateEditingState()
      }
    ]
    // Open/Save panels may edit in a remote AppKit process. Keep their exact
    // native menu actions, rather than resolving the parent's old responder.
    if let window {
      sheetObservers = [
        NotificationCenter.default.addObserver(forName: NSWindow.willBeginSheetNotification,
            object: window, queue: .main) { [weak self] _ in self?.restoreNativeActions() },
        NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification,
            object: window, queue: .main) { [weak self] _ in self?.installFlutterActions() }
      ]
    }
    // The accessibility field editor may consume these before menu dispatch.
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, self.flutterEditor != nil,
            let method = self.method(for: event)
      else { return event }
      self.channel.invokeMethod(method, arguments: nil)
      return nil
    }
  }

  private func invalidateEditingState() {
    menuGeneration += 1
    stateRequestPending = false
    editingState = [:]
  }

  private func refreshEditingState() {
    guard !stateRequestPending else { return }
    guard let editor = flutterEditor else {
      editingState = [:]
      return
    }
    stateRequestPending = true
    let generation = menuGeneration
    channel.invokeMethod("getEditingState", arguments: nil) { [weak self, weak editor] reply in
      guard let self, generation == self.menuGeneration else { return }
      self.stateRequestPending = false
      guard let editor, self.flutterEditor === editor,
            let state = reply as? [String: Bool], state != self.editingState else { return }
      self.editingState = state
      // AppKit validation is synchronous. Refresh when its asynchronous state
      // changes, without starting an update/query loop for identical snapshots.
      var updated = Set<ObjectIdentifier>()
      for original in self.originalItems {
        if let menu = original.item.menu, updated.insert(ObjectIdentifier(menu)).inserted {
          menu.update()
        }
      }
    }
  }

  private func method(for event: NSEvent) -> String? {
    guard let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }
    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    switch modifiers {
    case [.command]: return keyMethods[key]
    case [.command, .shift]: return key == "z" ? "redo" : nil
    case [.command, .option, .shift]: return key == "v" ? "paste" : nil
    default: return nil
    }
  }

  private func replaceEditingActions(in menu: NSMenu) {
    for item in menu.items {
      if let submenu = item.submenu { replaceEditingActions(in: submenu) }
      if let action = item.action, let method = methods[NSStringFromSelector(action)] {
        originalItems.append((item, item.target, action, method))
        item.target = self
        item.action = #selector(editFromMenu(_:))
      }
    }
  }

  private func restoreNativeActions() {
    for original in originalItems {
      original.item.target = original.target
      original.item.action = original.action
    }
  }

  private func installFlutterActions() {
    for original in originalItems {
      original.item.target = self
      original.item.action = #selector(editFromMenu(_:))
    }
  }

  private var flutterEditor: NSTextView? {
    guard let window, NSApp.keyWindow === window, window.attachedSheet == nil,
          let editor = window.firstResponder as? NSTextView,
          editor.window === window,
          Bundle(for: type(of: editor)) == Bundle(for: FlutterViewController.self)
    else { return nil }
    return editor
  }

  @objc private func editFromMenu(_ sender: NSMenuItem) {
    guard let original = originalItems.first(where: { $0.item === sender }) else { return }
    if flutterEditor != nil {
      // EditableText retains its own read-only, obscured-text and selection rules.
      // Send only the action; never transport editor or clipboard text here.
      channel.invokeMethod(original.method, arguments: nil)
    } else {
      let native = NSMenuItem(title: sender.title, action: original.action,
                              keyEquivalent: sender.keyEquivalent)
      NSApp.sendAction(original.action, to: nil, from: native)
    }
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    guard let original = originalItems.first(where: { $0.item === menuItem }) else { return false }
    if flutterEditor != nil {
      // Accessibility menu opening also validates, but may not emit tracking
      // notifications. Coalesce the requests from all items in this pass.
      refreshEditingState()
      return editingState[original.method] ?? false
    }
    let native = NSMenuItem(title: menuItem.title, action: original.action,
                            keyEquivalent: menuItem.keyEquivalent)
    guard let target = NSApp.target(forAction: original.action, to: nil, from: native)
    else { return false }
    if let validator = target as? NSMenuItemValidation {
      return validator.validateMenuItem(native)
    }
    if let validator = target as? NSUserInterfaceValidations {
      return validator.validateUserInterfaceItem(native)
    }
    return true
  }
}
