// Owned AppKit control for distinguishing CUA input delivery from Flutter UI.
// No event synthesis, global monitors, network, Keychain, or personal data.
import AppKit

func report(_ kind: String, _ facts: [String: Any]) {
  let record: [String: Any] = ["kind": kind, "facts": facts]
  guard let bytes = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
        let line = String(data: bytes, encoding: .utf8) else { return }
  FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

final class InputControl: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
  var window: NSWindow!
  var field: NSTextField!
  var second: NSTextField!
  var scroll: NSScrollView!
  var monitor: Any?
  var keys = 0
  var pointers = 0
  var wheels = 0
  var edits = 0

  func applicationDidFinishLaunching(_ notification: Notification) {
    let menu = NSMenu()
    let root = NSMenuItem()
    let submenu = NSMenu()
    let quit = NSMenuItem(title: "退出原生输入对照", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    quit.target = NSApp
    submenu.addItem(quit)
    root.submenu = submenu
    menu.addItem(root)
    NSApp.mainMenu = menu

    window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 800, height: 600),
                      styleMask: [.titled, .closable, .miniaturizable, .resizable],
                      backing: .buffered, defer: false)
    window.title = "Mac 原生输入独立对照"
    window.delegate = self
    window.isReleasedWhenClosed = false
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    window.contentView = view

    let label = NSTextField(labelWithString: "仅本窗口的合成文本、按键与滚动；没有资料库或系统权限请求")
    label.frame = NSRect(x: 20, y: 555, width: 760, height: 24)
    view.addSubview(label)
    field = NSTextField(string: "NativeBaseline")
    field.frame = NSRect(x: 20, y: 510, width: 470, height: 30)
    field.setAccessibilityLabel("原生名称对照")
    field.delegate = self
    view.addSubview(field)
    second = NSTextField(string: "SecondBaseline")
    second.frame = NSRect(x: 20, y: 465, width: 470, height: 30)
    second.setAccessibilityLabel("原生说明对照")
    second.delegate = self
    view.addSubview(second)
    field.nextKeyView = second
    second.nextKeyView = field

    let button = NSButton(title: "输出本窗口检查点", target: self, action: #selector(checkpoint))
    button.frame = NSRect(x: 520, y: 510, width: 250, height: 30)
    view.addSubview(button)
    scroll = NSScrollView(frame: NSRect(x: 20, y: 20, width: 760, height: 420))
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = false
    scroll.autoresizingMask = [.width, .height]
    let document = NSTextView(frame: NSRect(x: 0, y: 0, width: 720, height: 2400))
    document.isEditable = false
    document.isSelectable = true
    document.isVerticallyResizable = true
    document.autoresizingMask = [.width]
    document.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    document.string = (1...100).map { "原生滚动合成行 \($0)" }.joined(separator: "\n") + "\n文档底部"
    document.setAccessibilityLabel("原生滚动文档")
    scroll.documentView = document
    view.addSubview(scroll)

    // Local monitor only: deliberately retain nil-window events too. Filtering
    // by event.window alone could hide a delivery-routing difference.
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .scrollWheel]) { [weak self] event in
      guard let self else { return event }
      if event.type == .keyDown { self.keys += 1 }
      if event.type == .leftMouseDown { self.pointers += 1 }
      if event.type == .scrollWheel { self.wheels += 1 }
      var facts: [String: Any] = ["type": event.type.rawValue,
        "flags": event.modifierFlags.rawValue, "hasWindow": event.window != nil,
        "matchesOwnedWindow": event.window === self.window]
      // NSEvent.h permits keyCode only for keyDown/keyUp/flagsChanged.
      // An observer must not query key-only properties on pointer events.
      if event.type == .keyDown { facts["keyCode"] = event.keyCode }
      if event.type == .scrollWheel { facts["dy"] = event.scrollingDeltaY }
      report("nativeEvent", facts)
      return event
    }
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    window.makeFirstResponder(field)
    checkpoint()
    report("ready", ["pid": ProcessInfo.processInfo.processIdentifier,
      "keychainUsed": false, "flutterUsed": false, "monitorIsLocalOnly": true])
  }

  func controlTextDidChange(_ notification: Notification) {
    edits += 1
    checkpoint()
  }

  @objc func checkpoint() {
    report("checkpoint", ["name": field.stringValue, "description": second.stringValue,
      "keys": keys, "pointerDowns": pointers, "scrollEvents": wheels, "textChanges": edits,
      "scrollY": scroll.contentView.bounds.origin.y,
      "appActive": NSApp.isActive, "windowKey": window.isKeyWindow,
      "windowVisible": window.isVisible])
  }

  func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
  func applicationWillTerminate(_ notification: Notification) {
    checkpoint()
    if let monitor { NSEvent.removeMonitor(monitor) }
    report("terminated", ["normalApplicationTermination": true])
  }
}

let app = NSApplication.shared
let delegate = InputControl()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
