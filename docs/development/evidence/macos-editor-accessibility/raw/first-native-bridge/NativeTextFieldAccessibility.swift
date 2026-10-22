import Cocoa

/// Names only the owning Flutter view's unambiguously matched AppKit fields.
/// The public AppKit adapter never reads/writes text or moves input focus.
final class NativeTextFieldAccessibility {
  private struct Label {
    let name: String
    let rect: NSRect // Flutter logical coordinates, top-left origin.
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
  private let assignments = NSMapTable<NSTextField, Assignment>.weakToStrongObjects()

  init(view: NSView) { self.view = view }

  /// Invalid updates preserve the previous labels. An empty list restores them.
  @discardableResult
  func update(_ value: Any?) -> Bool {
    guard let rows = value as? [[String: Any]], rows.count <= 4096 else { return false }
    var next: [Label] = []
    for row in rows {
      guard Set(row.keys) == Set(["label", "left", "top", "width", "height"]),
            let name = row["label"] as? String, !name.isEmpty, name.utf8.count <= 512 else { return false }
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
      next.append(Label(name: name, rect: rect))
    }
    labels = next
    if labels.isEmpty {
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
    let nativeFrames = fields.map { ($0, $0.accessibilityFrame()) }
    let targets = labels.map { label -> (String, NSRect) in
      let r = label.rect
      let y = view.isFlipped ? r.minY : view.bounds.maxY - r.maxY
      let local = NSRect(x: r.minX, y: y, width: r.width, height: r.height)
      return (label.name, window.convertToScreen(view.convert(local, to: nil)))
    }
    func matches(_ a: NSRect, _ b: NSRect) -> Bool {
      !a.isEmpty && abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 &&
        abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }
    var kept = Set<ObjectIdentifier>()
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
      kept.insert(ObjectIdentifier(field))
    }
    for field in assignments.keyEnumerator().allObjects.compactMap({ $0 as? NSTextField }) {
      if !kept.contains(ObjectIdentifier(field)) { restore(field) }
    }
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
