import AppKit
import WebKit

/// Synthetic test application only. Commands mutate fixture state, never accept
/// a fill request. The production adapter knows none of this file protocol.
private final class Fixture: NSObject, NSApplicationDelegate {
  let root: URL
  let cover: Bool
  var windows: [NSWindow] = []
  var fields: [String: NSTextField] = [:]
  var last = ""
  var expected = ""
  var web: WKWebView?
  var contextLabel: NSTextField?
  init(_ root: URL, cover: Bool) { self.root = root; self.cover = cover }
  func save(_ name: String, _ value: [String: Any]) {
    try! JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(name), options: .atomic)
  }
  func makeField(_ id: String, row: Int) -> NSTextField {
    let field: NSTextField = cover ? NSTextField() : NSSecureTextField()
    field.frame = NSRect(x: 24, y: 180 - row * 60, width: 340, height: 32)
    field.setAccessibilityIdentifier(id)
    field.placeholderString = id
    return field
  }
  func applicationDidFinishLaunching(_ note: Notification) {
    if let data = try? Data(contentsOf: root.appendingPathComponent("case.json")),
       let c = try? JSONSerialization.jsonObject(with: data) as? [String: String] { expected = c["expected"] ?? "" }
    for i in 0..<(cover ? 1 : 2) {
      let window = NSWindow(contentRect: NSRect(x: 100 + i * 30, y: 130 + i * 30, width: 460, height: 280),
        styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
      window.title = "Synthetic native \(i)"
      window.setAccessibilityIdentifier("native-\(i)")
      window.isReleasedWhenClosed = false
      windows.append(window)
      for j in 0..<2 {
        let id = "field-\(i)-\(j)", field = makeField("field-\(i)-\(j)", row: j)
        fields[id] = field; window.contentView!.addSubview(field)
      }
      if !cover && i == 0 { fields["field-0-0"]!.stringValue = "old-synthetic" }
      if !cover && i == 0 {
        let label = NSTextField(labelWithString: "synthetic-context-1")
        label.frame = NSRect(x: 20, y: 240, width: 400, height: 20)
        label.setAccessibilityIdentifier("context-label")
        window.contentView!.addSubview(label); contextLabel = label
      }
      window.makeFirstResponder(fields["field-\(i)-1"])
      window.orderFrontRegardless()
    }
    if !cover {
      let window = NSWindow(contentRect: NSRect(x: 160, y: 180, width: 460, height: 280),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.title = "Synthetic embedded web"
      window.setAccessibilityIdentifier("web-window")
      window.isReleasedWhenClosed = false
      let view = WKWebView(frame: window.contentView!.bounds)
      view.isInspectable = false
      window.contentView!.addSubview(view)
      view.loadHTMLString("<input id='web-password' type='password' aria-label='Password'>", baseURL: nil)
      web = view; windows.append(window); window.orderFrontRegardless()
    }
    save((cover ? "cover" : "target") + "-pid.json", ["pid": getpid()])
    Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in self.tick() }
    tick()
  }
  func perform(_ action: String) {
    switch action {
    case "activate": windows[0].makeKeyAndOrderFront(nil); NSApp.activate(); windows[0].makeFirstResponder(fields["field-0-1"])
    case "cover", "aside":
      windows[0].setFrame(action == "cover" ? NSRect(x: 50, y: 80, width: 1050, height: 850) : NSRect(x: 850, y: 100, width: 400, height: 320), display: true)
      fields["field-0-0"]?.stringValue = ""
      windows[0].makeKeyAndOrderFront(nil); NSApp.activate(); windows[0].makeFirstResponder(fields["field-0-0"])
    case "focus-b": windows[0].makeFirstResponder(fields["field-0-1"])
    case "show-web": windows.last!.makeKeyAndOrderFront(nil); NSApp.activate()
    case "minimize": windows[0].miniaturize(nil)
    case "hide": NSApp.hide(nil)
    case "disable": fields["field-0-0"]!.isEnabled = false
    case "readonly": fields["field-0-0"]!.isEditable = false
    case "close": windows[0].close()
    case "rebuild":
      fields["field-0-0"]!.removeFromSuperview()
      let field = makeField("field-0-0", row: 0)
      fields["field-0-0"] = field; windows[0].contentView!.addSubview(field)
    case "duplicate": windows[0].contentView!.addSubview(makeField("field-0-0", row: 2))
    case "context": contextLabel?.stringValue = "synthetic-context-2"
    case "quit": NSApp.terminate(nil)
    default: break
    }
  }
  func tick() {
    let prefix = cover ? "cover" : "target"
    if let data = try? Data(contentsOf: root.appendingPathComponent(prefix + "-command.json")),
       let c = try? JSONSerialization.jsonObject(with: data) as? [String: String], let id = c["id"], id != last {
      last = id; perform(c["action"] ?? ""); save(prefix + "-ack.json", ["id": id])
    }
    let states = fields.mapValues { ["matches": $0.stringValue.utf16.elementsEqual(expected.utf16), "old": $0.stringValue == "old-synthetic",
      "empty": $0.stringValue.isEmpty, "focused": $0.currentEditor() != nil,
      "workInputMatches": $0.stringValue == "work-🙂"] }
    save(prefix + "-state.json", ["at": Date().timeIntervalSince1970, "pid": getpid(), "fields": states,
      "active": NSApp.isActive, "hidden": NSApp.isHidden,
      "windows": windows.map { ["visible": $0.isVisible, "miniaturized": $0.isMiniaturized,
        "occlusionVisible": $0.occlusionState.contains(.visible)] }])
  }
}
@main enum NativeFixtureMain {
  static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = Fixture(URL(fileURLWithPath: CommandLine.arguments[1]), cover: CommandLine.arguments.contains("--cover"))
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
}
