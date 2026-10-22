import Cocoa

private struct Failure: Error { let message: String }
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() { throw Failure(message: message) }
}

@main
private struct Probe {
  static func main() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let root = window.contentView!
    let field = NSTextField(frame: NSRect(x: 20, y: 180, width: 200, height: 30))
    field.stringValue = "synthetic-unchanged"
    field.setAccessibilityLabel("Original")
    root.addSubview(field)
    func row(_ label: String, top: Double = 90) -> [String: Any] {
      ["label": label, "left": 20.0, "top": top, "width": 200.0, "height": 30.0]
    }
    let adapter = NativeTextFieldAccessibility(view: root)
    var passed = 0
    func test(_ name: String, _ body: () throws -> Void) rethrows {
      try body(); passed += 1; print("PASS \(name)")
    }
    try test("purpose attaches through public AppKit without changing text or focus") {
      let responder = window.firstResponder
      try check(adapter.update([row("信息名称")]), "valid labels refused")
      try check(field.accessibilityLabel() == "信息名称", "native label missing")
      try check(field.stringValue == "synthetic-unchanged", "text changed")
      try check(window.firstResponder === responder, "focus changed")
    }
    try test("malformed, boolean, duplicate and content-bearing metadata preserve prior assignment") {
      var extra = row("Ignored"); extra["value"] = "not-transported"
      var boolean = row("Ignored"); boolean["width"] = true
      var nan = row("Ignored"); nan["top"] = Double.nan
      for value: Any in [extra, [extra], [boolean], [nan], [row("A"), row("B")],
                         [row("")], [row(String(repeating: "x", count: 513))]] {
        try check(!adapter.update(value), "invalid metadata accepted")
        try check(field.accessibilityLabel() == "信息名称", "invalid update changed labels")
      }
    }
    try test("clearing restores original labels and stops ownership") {
      try check(adapter.update([] as [[String: Any]]), "clear refused")
      try check(field.accessibilityLabel() == "Original", "original label not restored")
    }
    try test("owner changes are not overwritten during restoration") {
      try check(adapter.update([row("说明")]), "update refused")
      field.setAccessibilityLabel("Owner changed")
      adapter.update([] as [[String: Any]])
      try check(field.accessibilityLabel() == "Owner changed", "owner label overwritten")
      field.setAccessibilityLabel("Original")
    }
    try test("ambiguous overlapping native fields receive no guessed labels") {
      let other = NSTextField(frame: field.frame)
      other.setAccessibilityLabel("Other")
      root.addSubview(other)
      defer { other.removeFromSuperview() }
      try check(adapter.update([row("Ambiguous")]), "valid metadata refused")
      try check(field.accessibilityLabel() == "Original", "ambiguous field labelled")
      try check(other.accessibilityLabel() == "Other", "ambiguous sibling labelled")
    }
    try test("secure and unmatched sibling controls retain their own names and values") {
      let secure = NSSecureTextField(frame: field.frame)
      secure.setAccessibilityLabel("Secure input")
      secure.stringValue = "synthetic-secure-unchanged"
      let sibling = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 30))
      sibling.setAccessibilityLabel("Unrelated")
      root.addSubview(secure); root.addSubview(sibling)
      defer { secure.removeFromSuperview(); sibling.removeFromSuperview() }
      try check(adapter.update([row("公开说明")]), "valid update refused")
      try check(field.accessibilityLabel() == "公开说明", "intended field not labelled")
      try check(secure.accessibilityLabel() == "Secure input" &&
                secure.stringValue == "synthetic-secure-unchanged", "secure editor changed")
      try check(sibling.accessibilityLabel() == "Unrelated", "sibling changed")
    }
    try test("changed geometry requires a new matching location") {
      field.setFrameOrigin(NSPoint(x: 20, y: 130))
      adapter.update([row("Old location")])
      try check(field.accessibilityLabel() == "Original", "stale location assigned")
      adapter.update([row("New location", top: 140)])
      try check(field.accessibilityLabel() == "New location", "new location not assigned")
      adapter.update([] as [[String: Any]])
      field.setFrameOrigin(NSPoint(x: 20, y: 180))
    }
    try test("deinitialization releases the timer and restores native labels") {
      var temporary: NativeTextFieldAccessibility? = NativeTextFieldAccessibility(view: root)
      temporary!.update([row("Temporary")])
      try check(field.accessibilityLabel() == "Temporary", "temporary update failed")
      temporary = nil
      try check(field.accessibilityLabel() == "Original", "deinit did not restore")
    }
    print("PASS total=\(passed)")
    window.close()
  }
}
