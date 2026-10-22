import Cocoa

/// Maintains the owning Flutter view's unambiguously matched AppKit AX shims.
/// Synchronizes inactive ordinary values and the already-chosen keyboard
/// field's AX focus/selection, without editing active text or secure inputs.
final class NativeTextFieldAccessibility {
  private struct KeyboardState {
    let focused: Bool
    let selection: NSRange?
    let composing: Bool
  }
  private struct Label {
    let name: String
    let rect: NSRect // Flutter logical coordinates, top-left origin.
    let text: String?
    let keyboard: KeyboardState?
  }
  private final class Assignment: NSObject {
    let original: String?
    var applied: String
    init(original: String?, applied: String) {
      self.original = original
      self.applied = applied
    }
  }
  private weak var view: NSView?
  private var labels: [Label] = []
  private var timer: Timer?
  private weak var lastKeyboardField: NSTextField?
  private let ownerIsActive: (NSWindow) -> Bool
  private let assignments = NSMapTable<NSTextField, Assignment>.weakToStrongObjects()

  init(view: NSView, ownerIsActive: @escaping (NSWindow) -> Bool = {
    $0.isKeyWindow && $0.isVisible && NSApp.isActive
  }) {
    self.view = view
    self.ownerIsActive = ownerIsActive
  }

  /// Invalid updates preserve the previous labels. An empty list restores them.
  @discardableResult
  func update(_ value: Any?) -> Bool {
    guard let rows = value as? [[String: Any]], rows.count <= 4096 else { return false }
    var next: [Label] = []
    for row in rows {
      let keys = Set(["label", "left", "top", "width", "height"])
      guard Set(row.keys) == keys || Set(row.keys) == keys.union(["text"]) ||
            Set(row.keys) == keys.union(["text", "keyboardFocused", "selection", "composing"]),
            let name = row["label"] as? String, !name.isEmpty, name.utf8.count <= 512 else { return false }
      if row.keys.contains("text"), !(row["text"] is String) { return false }
      var keyboard: KeyboardState?
      if row.keys.contains("keyboardFocused") {
        guard let focused = row["keyboardFocused"] as? NSNumber,
              CFGetTypeID(focused) == CFBooleanGetTypeID(),
              let text = row["text"] as? String else { return false }
        func offsets(_ value: Any?) -> [Int]? {
          guard let numbers = value as? [NSNumber], numbers.count == 2,
                numbers.allSatisfy({
                  CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite &&
                    $0.doubleValue.rounded() == $0.doubleValue &&
                    $0.doubleValue >= -1 && $0.doubleValue <= Double(text.utf16.count)
                }) else { return nil }
          let values = numbers.map { $0.intValue }
          guard values == [-1, -1] || values.allSatisfy({ $0 >= 0 }) else { return nil }
          return values
        }
        guard let selection = offsets(row["selection"]),
              let composing = offsets(row["composing"]), composing[0] <= composing[1] else { return false }
        keyboard = KeyboardState(focused: focused.boolValue,
          selection: selection[0] < 0 ? nil : NSRange(location: min(selection[0], selection[1]),
                                                       length: abs(selection[1] - selection[0])),
          composing: composing[0] >= 0 && composing[1] > composing[0])
      }
      var numbers: [Double] = []
      for key in ["left", "top", "width", "height"] {
        guard let n = row[key] as? NSNumber,
              CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, abs(n.doubleValue) <= 100000 else { return false }
        numbers.append(n.doubleValue)
      }
      guard numbers[2] > 0, numbers[3] > 0 else { return false }
      let rect = NSRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
      guard !next.contains(where: { $0.rect == rect }) else { return false }
      next.append(Label(name: name, rect: rect, text: row["text"] as? String, keyboard: keyboard))
    }
    guard next.filter({ $0.keyboard?.focused == true }).count <= 1 else { return false }
    labels = next
    if labels.isEmpty {
      lastKeyboardField = nil
      timer?.invalidate()
      timer = nil
    } else if timer == nil {
      // Flutter creates its AppKit shims lazily when accessibility queries them.
      let polling = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
        guard let self, self.view?.window?.isVisible == true else { return }
        self.reconcile()
      }
      RunLoop.main.add(polling, forMode: .common)
      timer = polling
    }
    reconcile()
    return true
  }

  private func reconcile() {
    if labels.isEmpty {
      for field in assignments.keyEnumerator().allObjects.compactMap({ $0 as? NSTextField }) { restore(field) }
      return
    }
    guard let view, let window = view.window else { return }
    // Native sheets own their own names and editors, including secure inputs.
    guard window.attachedSheet == nil else { return }
    var fields: [NSTextField] = []
    func visit(_ node: NSView) {
      if let field = node as? NSTextField, !(field is NSSecureTextField) {
        fields.append(field)
      }
      for child in node.subviews { visit(child) }
    }
    visit(view)
    func liveFrame(_ field: NSTextField) -> NSRect {
      guard let parent = field.superview else { return .zero }
      return window.convertToScreen(parent.convert(field.frame, to: nil))
    }
    let nativeFrames = fields.map { ($0, liveFrame($0)) }
    let targets = labels.map { label -> (String, NSRect, String?, KeyboardState?) in
      let r = label.rect
      let y = view.isFlipped ? r.minY : view.bounds.maxY - r.maxY
      let local = NSRect(x: r.minX, y: y, width: r.width, height: r.height)
      return (label.name, window.convertToScreen(view.convert(local, to: nil)), label.text, label.keyboard)
    }
    func matches(_ a: NSRect, _ b: NSRect) -> Bool {
      !a.isEmpty && abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 &&
        abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }
    var kept = Set<ObjectIdentifier>()
    var keyboardField: (NSTextField, String, KeyboardState)?
    for (field, frame) in nativeFrames {
      let possible = targets.filter { matches(frame, $0.1) }
      guard possible.count == 1, let target = possible.first,
            nativeFrames.filter({ matches($0.1, target.1) }).count == 1 else { continue }
      let record = assignments.object(forKey: field) ??
        Assignment(original: field.accessibilityLabel(), applied: target.0)
      record.applied = target.0
      assignments.setObject(record, forKey: field)
      if field.accessibilityLabel() != target.0 {
        field.setAccessibilityLabel(target.0)
        NSAccessibility.post(element: field, notification: .titleChanged)
      }
      // Flutter's shared field editor can leave an inactive shim with the next
      // field's value, or with an empty initial cache. Never touch a live editor:
      // doing so could replace selection or an in-progress IME composition.
      if let text = target.2, field.currentEditor() == nil, field.stringValue != text {
        field.stringValue = text
        NSAccessibility.post(element: field, notification: .valueChanged)
      }
      if let text = target.2, let keyboard = target.3, keyboard.focused {
        keyboardField = (field, text, keyboard)
      }
      kept.insert(ObjectIdentifier(field))
    }
    for field in assignments.keyEnumerator().allObjects.compactMap({ $0 as? NSTextField }) {
      if !kept.contains(ObjectIdentifier(field)) { restore(field) }
    }
    alignKeyboardField(keyboardField, window: window)
  }

  private func alignKeyboardField(_ target: (NSTextField, String, KeyboardState)?, window: NSWindow) {
    guard let (field, text, keyboard) = target else { lastKeyboardField = nil; return }
    guard ownerIsActive(window),
          lastKeyboardField !== field, let selection = keyboard.selection,
          !keyboard.composing,
          (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return }
    // AppKit can select all when assigning AX focus. Restore only the native
    // editor's cache from the unchanged Flutter selection, never its text.
    // Do this once per keyboard transition so VoiceOver remains free to browse.
    lastKeyboardField = field
    field.setAccessibilityFocused(true)
    if let editor = field.currentEditor(), editor.string == text {
      editor.selectedRange = selection
    }
    NSAccessibility.post(element: field, notification: .focusedUIElementChanged)
  }

  private func restore(_ field: NSTextField) {
    if let record = assignments.object(forKey: field), field.accessibilityLabel() == record.applied {
      field.setAccessibilityLabel(record.original)
      NSAccessibility.post(element: field, notification: .titleChanged)
    }
    assignments.removeObject(forKey: field)
  }

  deinit {
    timer?.invalidate()
    for field in assignments.keyEnumerator().allObjects.compactMap({ $0 as? NSTextField }) { restore(field) }
  }
}
