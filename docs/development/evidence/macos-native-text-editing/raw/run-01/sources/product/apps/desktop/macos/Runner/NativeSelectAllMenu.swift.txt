import Cocoa
import FlutterMacOS

/// Accessibility's NSTextView selection can diverge from EditableText. Route
/// Select All to Flutter's action, preserving AppKit behavior in native sheets.
final class NativeSelectAllMenu: NSObject, NSMenuItemValidation {
  private weak var window: NSWindow?
  private let selectAll = NSSelectorFromString("selectAll:")
  private let channel: FlutterMethodChannel
  private var keyMonitor: Any?
  private var sheetObservers: [NSObjectProtocol] = []
  private var originalItems: [(item: NSMenuItem, target: AnyObject?, action: Selector?)] = []

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
    replaceSelectAll(in: menu)
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
    // The accessibility field editor consumes Cmd-A before menu dispatch.
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, self.flutterEditor != nil,
            event.modifierFlags.contains(.command),
            event.modifierFlags.intersection([.control, .option, .shift]).isEmpty,
            event.charactersIgnoringModifiers?.lowercased() == "a"
      else { return event }
      self.channel.invokeMethod("selectAll", arguments: nil)
      return nil
    }
  }

  private func replaceSelectAll(in menu: NSMenu) {
    for item in menu.items {
      if let submenu = item.submenu { replaceSelectAll(in: submenu) }
      if item.action == selectAll {
        originalItems.append((item, item.target, item.action))
        item.target = self
        item.action = #selector(selectAllFromMenu(_:))
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
      original.item.action = #selector(selectAllFromMenu(_:))
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

  @objc private func selectAllFromMenu(_ sender: NSMenuItem) {
    if flutterEditor != nil {
      channel.invokeMethod("selectAll", arguments: nil)
    } else {
      let native = NSMenuItem(title: sender.title, action: selectAll,
                              keyEquivalent: sender.keyEquivalent)
      NSApp.sendAction(selectAll, to: nil, from: native)
    }
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if flutterEditor != nil { return true }
    let native = NSMenuItem(title: menuItem.title, action: selectAll,
                            keyEquivalent: menuItem.keyEquivalent)
    guard let target = NSApp.target(forAction: selectAll, to: nil, from: native)
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
