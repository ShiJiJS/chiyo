import Cocoa
import FlutterMacOS

/// Accessibility's NSTextView can diverge from EditableText. Route editing
/// actions to Flutter, preserving AppKit behavior in native sheets.
final class NativeTextEditingMenu: NSObject, NSMenuItemValidation {
  private weak var window: NSWindow?
  private let methods = ["selectAll:": "selectAll", "copy:": "copy",
                         "cut:": "cut", "paste:": "paste"]
  private let keyMethods = ["a": "selectAll", "c": "copy", "x": "cut", "v": "paste"]
  private let channel: FlutterMethodChannel
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
    for observer in sheetObservers { NotificationCenter.default.removeObserver(observer) }
  }

  func install(in menu: NSMenu) {
    guard keyMonitor == nil else { return }
    replaceEditingActions(in: menu)
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
            event.modifierFlags.contains(.command),
            event.modifierFlags.intersection([.control, .option, .shift]).isEmpty,
            let key = event.charactersIgnoringModifiers?.lowercased(),
            let method = self.keyMethods[key]
      else { return event }
      self.channel.invokeMethod(method, arguments: nil)
      return nil
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
    if flutterEditor != nil { return true }
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
