import Cocoa
import UniformTypeIdentifiers

final class Control: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 360),
                        styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
  let secure = NSSecureTextField(string: "SyntheticSecret42")
  let plain = NSTextField(string: "SyntheticPlain42")
  var saved: [[NSPasteboard.PasteboardType: Data]]?
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    window.title = "Synthetic native secure control — no Keychain"
    window.center()
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 360))
    window.contentView = view
    func label(_ text: String, _ y: CGFloat) {
      let label = NSTextField(labelWithString: text)
      label.frame = NSRect(x: 30, y: y, width: 630, height: 24)
      view.addSubview(label)
    }
    label("Native NSSecureTextField — synthetic only", 300)
    secure.frame = NSRect(x: 30, y: 255, width: 630, height: 30)
    secure.placeholderString = "Native secure synthetic"
    secure.setAccessibilityLabel("Native secure synthetic")
    secure.delegate = self
    view.addSubview(secure)
    label("Native ordinary NSTextField — synthetic only", 210)
    plain.frame = NSRect(x: 30, y: 165, width: 630, height: 30)
    plain.setAccessibilityLabel("Native ordinary synthetic")
    view.addSubview(plain)
    let panel = NSButton(title: "Open synthetic save panel", target: self, action: #selector(openPanel))
    panel.frame = NSRect(x: 30, y: 90, width: 280, height: 32)
    view.addSubview(panel)
    let bar = NSMenu()
    let appItem = NSMenuItem(); let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Quit MacAXNativeControl", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu; bar.addItem(appItem)
    let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    let edit = NSMenu(title: "Edit")
    for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
      edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
    }
    editItem.submenu = edit; bar.addItem(editItem); NSApp.mainMenu = bar
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    print("QA_NATIVE ready syntheticOnly=true"); fflush(stdout)
  }
  func controlTextDidChange(_ obj: Notification) {
    print("QA_NATIVE secureKnownExact=\(secure.stringValue == "SyntheticSecret42")"); fflush(stdout)
  }
  @objc func openPanel() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "SyntheticNativeAX.txt"
    panel.allowedContentTypes = [.plainText]
    panel.beginSheetModal(for: window) { response in
      print("QA_NATIVE panelCancelled=\(response == .cancel)"); fflush(stdout)
    }
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let delegate = Control()
app.delegate = delegate
app.run()
