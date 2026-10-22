import Cocoa

private struct Failure: Error { let message: String }
private final class StaleAXField: NSTextField {
  override func accessibilityFrame() -> NSRect { .zero }
}
private final class ActiveAXField: NSTextField {
  let editor = NSTextView()
  override func currentEditor() -> NSText? { editor }
}
private final class FocusAXField: NSTextField {
  let editor = NSTextView()
  var focusAssignments = 0
  override func currentEditor() -> NSText? { editor }
  override func setAccessibilityFocused(_ value: Bool) {
    if value {
      focusAssignments += 1
      editor.selectedRange = NSRange(location: 0, length: editor.string.utf16.count)
    }
  }
}
private final class MarkedEditor: NSTextView {
  var marked = true
  override func hasMarkedText() -> Bool { marked }
}
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
    try test("nested live view geometry works when the AX frame is stale") {
      let nested = NSView(frame: NSRect(x: 40, y: 60, width: 300, height: 240))
      let stale = StaleAXField(frame: NSRect(x: 20, y: 180, width: 200, height: 30))
      stale.setAccessibilityLabel("Nested original")
      nested.addSubview(stale); root.addSubview(nested)
      defer { adapter.update([] as [[String: Any]]); nested.removeFromSuperview() }
      try check(adapter.update([["label": "Nested purpose", "left": 60.0,
                                 "top": 30.0, "width": 200.0, "height": 30.0]]), "nested labels refused")
      try check(stale.accessibilityLabel() == "Nested purpose", "stale AX frame blocked live match")
      try check(field.accessibilityLabel() == "Original", "unrelated field changed")
    }
    try test("ordinary inactive cache mirrors its own value without changing focus or editor") {
      let responder = window.firstResponder
      var metadata = row("Ordinary value"); metadata["text"] = "synthetic-correct"
      try check(adapter.update([metadata]), "ordinary text refused")
      try check(field.stringValue == "synthetic-correct", "inactive cache stale")
      try check(window.firstResponder === responder, "focus changed")
      metadata["text"] = false
      try check(!adapter.update([metadata]), "non-string value accepted")
      try check(field.stringValue == "synthetic-correct", "invalid value changed cache")
      adapter.update([] as [[String: Any]])
    }
    try test("active editor and secure text never receive ordinary cache writes") {
      field.removeFromSuperview()
      let active = ActiveAXField(frame: field.frame)
      active.stringValue = "active-original"
      active.editor.string = "synthetic-composition"
      let activeBefore = active.stringValue
      let secure = NSSecureTextField(frame: field.frame)
      secure.stringValue = "secure-original"
      root.addSubview(active); root.addSubview(secure)
      defer { adapter.update([] as [[String: Any]]); active.removeFromSuperview(); secure.removeFromSuperview(); root.addSubview(field) }
      var metadata = row("Active value"); metadata["text"] = "must-not-replace"
      try check(adapter.update([metadata]), "valid text refused")
      try check(active.stringValue == activeBefore, "active cache overwritten")
      try check(active.editor.string == "synthetic-composition", "composition changed")
      try check(secure.stringValue == "secure-original", "secure value overwritten")
    }
    func keyboardRow() -> [String: Any] {
      var data = row("Keyboard field")
      data["text"] = "Alpha"; data["keyboardFocused"] = true
      data["selection"] = [4, 1]; data["composing"] = [-1, -1]
      return data
    }
    try test("invalid keyboard payloads and multiple focused rows preserve state") {
      var badBool = keyboardRow(); badBool["keyboardFocused"] = 1
      var badOffset = keyboardRow(); badOffset["selection"] = [1.5, 2.0]
      var outside = keyboardRow(); outside["selection"] = [0, 6]
      var mixed = keyboardRow(); mixed["selection"] = [-1, 0]
      var backwards = keyboardRow(); backwards["composing"] = [3, 1]
      var extra = keyboardRow(); extra["target"] = "outside"
      var another = keyboardRow(); another["top"] = 140.0
      for rows in [[badBool], [badOffset], [outside], [mixed], [backwards], [extra], [keyboardRow(), another]] {
        try check(!adapter.update(rows), "invalid focus metadata accepted")
      }
    }
    try test("background windows do not receive AX focus") {
      field.removeFromSuperview()
      let native = FocusAXField(frame: field.frame)
      native.editor.string = "Alpha"
      root.addSubview(native)
      defer { adapter.update([] as [[String: Any]]); native.removeFromSuperview(); root.addSubview(field) }
      try check(adapter.update([keyboardRow()]), "valid focus metadata refused")
      try check(native.focusAssignments == 0, "background focus changed")
    }
    // Active-window policy is supplied only in these isolated contract tests.
    // Production defaults and actual Flutter/OS focus are checked through CUA;
    // the background guard above uses the real default policy.
    let activeAdapter = NativeTextFieldAccessibility(view: root, ownerIsActive: { _ in true })
    try test("keyboard AX transition restores selection once without reselecting during browsing") {
      field.removeFromSuperview()
      let native = FocusAXField(frame: field.frame)
      native.editor.string = "Alpha"
      root.addSubview(native)
      defer { activeAdapter.update([] as [[String: Any]]); native.removeFromSuperview(); root.addSubview(field) }
      let data = keyboardRow()
      try check(activeAdapter.update([data]), "valid focus metadata refused")
      try check(native.focusAssignments == 1 && native.editor.selectedRange == NSRange(location: 1, length: 3), "focus selection not restored")
      native.editor.selectedRange = NSRange(location: 2, length: 0)
      activeAdapter.update([data])
      try check(native.focusAssignments == 1 && native.editor.selectedRange == NSRange(location: 2, length: 0), "unchanged focus reselected editor")
      var blurred = data; blurred["keyboardFocused"] = false
      activeAdapter.update([blurred]); activeAdapter.update([data])
      try check(native.focusAssignments == 2, "returning keyboard focus not aligned")
    }
    try test("canonical or native marked text defers focus alignment until composition ends") {
      field.removeFromSuperview()
      let native = FocusAXField(frame: field.frame)
      native.editor.string = "Alpha"
      let marked = MarkedEditor(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
      root.addSubview(native); root.addSubview(marked)
      defer { activeAdapter.update([] as [[String: Any]]); marked.removeFromSuperview(); native.removeFromSuperview(); root.addSubview(field) }
      var composing = keyboardRow(); composing["composing"] = [1, 4]
      activeAdapter.update([composing])
      try check(native.focusAssignments == 0, "Dart composition focus changed")
      try check(window.makeFirstResponder(marked), "marked editor did not become responder")
      activeAdapter.update([keyboardRow()])
      try check(native.focusAssignments == 0, "native composition focus changed")
      marked.marked = false
      activeAdapter.update([keyboardRow()])
      try check(native.focusAssignments == 1, "focus not resumed after composition")
    }
    print("PASS total=\(passed)")
    window.close()
  }
}
