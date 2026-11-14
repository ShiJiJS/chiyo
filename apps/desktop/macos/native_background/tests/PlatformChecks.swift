import AppKit
import ApplicationServices
import Foundation

private func pump(_ seconds: Double) {
  let until = Date().addingTimeInterval(seconds)
  while Date() < until { RunLoop.current.run(until: min(until, Date().addingTimeInterval(0.005))) }
}
private struct Snapshot {
  let front: pid_t
  let field: AXUIElement?
  let fieldPID: pid_t
  let mouse: CGPoint
  let clipboard: Int
  init() {
    front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
    var value: CFTypeRef?
    if front > 0 { _ = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(front), kAXFocusedUIElementAttribute as CFString, &value) }
    if let value, CFGetTypeID(value) == AXUIElementGetTypeID() { field = unsafeBitCast(value, to: AXUIElement.self) }
    else { field = nil }
    var pid: pid_t = -1
    if let field { AXUIElementGetPid(field, &pid) }
    fieldPID = pid; mouse = CGEvent(source: nil)!.location
    clipboard = NSPasteboard.general.changeCount
  }
  var valid: Bool { front > 0 && field != nil && fieldPID == front }
  var wire: [String: Any] { ["at": Date().timeIntervalSince1970, "front": front, "focusPID": fieldPID,
    "valid": valid, "focusHash": field.map { CFHash($0) } ?? 0, "x": mouse.x, "y": mouse.y, "clipboard": clipboard] }
  func same(_ other: Snapshot) -> Bool {
    guard valid, other.valid, let field, let otherField = other.field else { return false }
    return front == other.front && CFEqual(field, otherField) && mouse == other.mouse && clipboard == other.clipboard
  }
}
nonisolated func typeIntoSyntheticCover(_ pid: pid_t) {
  let units = Array("work-🙂".utf16)
  for down in [true, false] {
    let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: 0, keyDown: down)!
    event.flags = []
    units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress!) }
    event.postToPid(pid)
  }
}

@main enum PlatformChecks {
  static func main() throws {
    _ = NSApplication.shared
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    func load(_ name: String) throws -> [String: Any] {
      try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(name))) as! [String: Any]
    }
    func save(_ name: String, _ value: Any) throws {
      try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]).write(to: root.appendingPathComponent(name), options: .atomic)
    }
    let config = try load("config.json")
    let application = try MacFocusApplication(executable: config["targetExecutable"] as! String, sha256: config["sha256"] as! String)
    let profile = MacNativeBackgroundProfile(application: application, bundleIdentifier: "local.chiyo.native-background.target",
      codeRequirement: config["codeRequirement"] as! String, windowIdentifiers: ["native-0"], fieldIdentifiers: ["field-0-0"],
      contextIdentifiers: ["context-label"])
    func command(_ prefix: String, _ action: String) throws {
      let id = UUID().uuidString
      try save(prefix + "-command.json", ["id": id, "action": action])
      if action == "quit" { pump(0.2); return }
      for _ in 0..<150 {
        pump(0.01)
        if (try? load(prefix + "-ack.json"))?["id"] as? String == id { return }
      }
      throw MacNativeBackgroundFailure.targetUnavailable
    }
    func activate(_ prefix: String, action: String = "activate") throws {
      try command(prefix, action)
      let open = Process(); open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      open.arguments = ["-a", root.appendingPathComponent(prefix + ".app").path]
      try open.run(); open.waitUntilExit(); pump(0.25)
    }
    var target: Process?
    let fixtureLog = FileHandle(forWritingAtPath: root.appendingPathComponent("fixture.log").path)!
    func start(_ expected: String) throws {
      if target?.isRunning == true { try command("target", "quit"); target?.waitUntilExit() }
      for name in ["target-pid.json", "target-state.json", "target-command.json", "target-ack.json"] { try? FileManager.default.removeItem(at: root.appendingPathComponent(name)) }
      try save("case.json", ["expected": expected])
      let process = Process(); process.executableURL = URL(fileURLWithPath: application.executable)
      process.arguments = [root.path]; process.standardOutput = fixtureLog; process.standardError = fixtureLog
      try process.run(); target = process
      for _ in 0..<200 {
        pump(0.01)
        if let state = try? load("target-state.json"), state["pid"] as? Int32 == process.processIdentifier { pump(0.2); return }
      }
      throw MacNativeBackgroundFailure.targetUnavailable
    }
    defer { try? command("target", "quit"); try? command("cover", "quit") }
    try start("synthetic")
    try activate("cover", action: "cover")
    let negative = Snapshot(); var negativeSamples: [[String: Any]] = []; var negativeOK = true
    for _ in 0..<25 { let s = Snapshot(); negativeSamples.append(s.wire); negativeOK = negativeOK && negative.same(s); pump(0.01) }
    let positive = Snapshot(); var positiveSamples: [[String: Any]] = []
    try command("cover", "focus-b")
    for _ in 0..<10 { positiveSamples.append(Snapshot().wire); pump(0.01) }
    try activate("target")
    for _ in 0..<10 { positiveSamples.append(Snapshot().wire); pump(0.01) }
    try activate("cover", action: "cover")
    let changedFocus = positiveSamples.contains { $0["focusHash"] as? CFHashCode != positive.field.map { CFHash($0) } }
    let changedFront = positiveSamples.contains { $0["front"] as? pid_t != positive.front }
    try save("calibration.json", ["negativePassed": negativeOK, "positiveFocusDetected": changedFocus,
      "positiveFrontDetected": changedFront, "negative": negativeSamples, "positive": positiveSamples])
    guard negativeOK, changedFocus, changedFront else { throw MacNativeBackgroundFailure.sessionUnavailable }
    var rows: [[String: Any]] = []
    for kind in ["background", "occluded", "minimized", "hidden", "disable", "readonly", "rebuild", "duplicate", "close", "restart", "context", "callback-disable", "unapproved", "web", "wrong-signature"] {
      let expected = " 新值🔐e\u{301} ! "
      try start(expected); try activate("target"); pump(0.25)
      if kind == "web" { try command("target", "show-web"); pump(0.5) }
      var selectedProfile = profile
      if kind == "web" {
        selectedProfile = MacNativeBackgroundProfile(application: application, bundleIdentifier: profile.bundleIdentifier,
          codeRequirement: profile.codeRequirement, windowIdentifiers: ["web-window"], fieldIdentifiers: ["web-password"])
      }
      if kind == "wrong-signature" {
        selectedProfile = MacNativeBackgroundProfile(application: application, bundleIdentifier: profile.bundleIdentifier,
          codeRequirement: "cdhash H\"0000000000000000000000000000000000000000\"", windowIdentifiers: profile.windowIdentifiers, fieldIdentifiers: profile.fieldIdentifiers)
      }
      let env = SystemMacNativeBackgroundEnvironment(profiles: kind == "unapproved" ? [] : [selectedProfile])
      let controller = MacNativeBackgroundController(environment: env, connected: { true })
      let access = MacNativeBackgroundAccess(scopeID: UUID(), application: application, isAuthorized: { true })
      var result = "refused", duplicateRefused = true
      var lease: UUID?
      var discoveryFailure: String?
      do {
        let descriptors = try controller.discover(access)
        guard descriptors.count == 1 else { throw MacNativeBackgroundFailure.ambiguousTarget }
        lease = try controller.capture(descriptors[0].candidateID, access: access)
      } catch { discoveryFailure = (error as? MacNativeBackgroundFailure)?.rawValue ?? "failure" }
      try command("target", "focus-b")
      if kind == "minimized" { try command("target", "minimize"); pump(0.6) }
      if kind == "hidden" { try command("target", "hide") }
      try activate("cover", action: kind == "background" ? "aside" : "cover")
      if ["disable", "readonly", "rebuild", "duplicate", "close", "context"].contains(kind) { try command("target", kind) }
      if kind == "restart" { try start(expected) }
      pump(0.1)
      let beforeFixture = try load("target-state.json")
      let baseline = Snapshot(); var trace = [baseline.wire]; var unchanged = baseline.valid
      let normal = ["background", "occluded", "minimized", "hidden"].contains(kind)
      if normal {
        let coverPID = (try load("cover-pid.json"))["pid"] as! pid_t
        // Independent user-work simulation, not a target-fill fallback.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { typeIntoSyntheticCover(coverPID) }
      }
      if let lease {
        switch controller.write(Data(expected.utf8), lease: lease, access: access, beforeDispatch: {
          if kind == "callback-disable" { try? command("target", "disable") }
          return true
        }) {
        case .setterAccepted: result = "setterAccepted"
        case .refused(let reason): result = "refused:" + reason.rawValue
        case .unknown: result = "unknown"
        }
        if case .refused = controller.write(Data("must-not-repeat".utf8), lease: lease, access: access, beforeDispatch: { true }) {} else { duplicateRefused = false }
      }
      for _ in 0..<30 { let s = Snapshot(); trace.append(s.wire); unchanged = unchanged && baseline.same(s); pump(0.01) }
      let after = try load("target-state.json")
      let fields = after["fields"] as! [String: [String: Bool]]
      let correct = fields["field-0-0"]!["matches"] == true
      let othersEmpty = fields.filter { $0.key != "field-0-0" }.allSatisfy { $0.value["empty"] == true }
      let working = (try load("cover-state.json"))["fields"] as? [String: [String: Bool]]
      let workAccepted = !normal || working?["field-0-0"]?["workInputMatches"] == true
      let internalBPreserved = !normal || (fields["field-0-1"]?["focused"] == true && fields["field-0-0"]?["focused"] == false)
      let capturedWhenRequired = ["unapproved", "web", "wrong-signature"].contains(kind) || lease != nil
      // A real WK window must be refused, including unavailable AX metadata.
      // Fail-closed metadata is not claimed as native-class identification.
      let webDetected = kind != "web" || ((beforeFixture["windows"] as? [[String: Any]])?.count == 3 && discoveryFailure != nil)
      let passed = workAccepted && internalBPreserved && webDetected && capturedWhenRequired && unchanged && duplicateRefused && othersEmpty && (normal ? correct && result == "setterAccepted" : !correct && result.hasPrefix("refused"))
      rows.append(["case": kind, "passed": passed, "result": result, "discoveryFailure": discoveryFailure as Any? ?? NSNull(),
        "before": beforeFixture, "after": after, "unchanged": unchanged, "duplicateRefused": duplicateRefused,
        "foregroundWorkAccepted": workAccepted, "internalBPreserved": internalBPreserved, "trace": trace])
      try save("platform-results.json", rows)
      print(kind + ": " + (passed ? "passed" : "FAILED") + " " + result)
      controller.close()
    }
    // Exercise frozen wire/lifecycle with an explicitly test-owned profile.
    try start("wire-假🙂"); try activate("target"); pump(0.25)
    try activate("cover", action: "cover")
    var ownerAlive = true
    let twoFields = MacNativeBackgroundProfile(application: application, bundleIdentifier: profile.bundleIdentifier, codeRequirement: profile.codeRequirement, windowIdentifiers: ["native-0"], fieldIdentifiers: ["field-0-0", "field-0-1"])
    let wire = MacNativeBackgroundWire(profiles: [twoFields], live: { ownerAlive })
    let scopeID = String(repeating: "a", count: 64)
    func request(_ command: String, _ payload: [String: Any] = [:], scope: String = scopeID) throws -> [String: Any] {
      let data = try JSONSerialization.data(withJSONObject: ["format": 1, "command": command, "scope": scope].merging(payload) { _, b in b })
      return try JSONSerialization.jsonObject(with: wire.handle(data)) as! [String: Any]
    }
    var wireChecks: [String: Bool] = [:]
    let found = try request("discover", ["appId": profile.bundleIdentifier])
    let discovered = found["targets"] as? [[String: Any]] ?? []
    let snapshot = discovered.first(where: { ($0["fieldLabel"] as? String)?.contains("field-0-0") == true }) ?? [:]
    wireChecks["stableMarkersDisambiguate"] = discovered.count == 2 && Set(discovered.compactMap { $0["fieldLabel"] as? String }).count == 2 && (snapshot["windowTitle"] as? String)?.contains("native-0") == true
    if let targetID = snapshot["targetId"] as? String {
      let first = try request("prepare", ["targetId": targetID])
      let lease = first["leaseId"] as? String ?? ""
      _ = try request("close", ["leaseId": lease]); _ = try request("close", ["leaseId": lease])
      let second = try request("prepare", ["targetId": targetID, "expected": snapshot])
      wireChecks["closeRetainsOriginalTarget"] = second["state"] as? String == "prepared"
      let newLease = second["leaseId"] as? String ?? ""
      wireChecks["setterAccepted"] = try request("setValue", ["leaseId": newLease, "bytes": Array("wire-假🙂".utf8)])["state"] as? String == "sent"
      wireChecks["sameLeaseNeverReplays"] = try request("setValue", ["leaseId": newLease, "bytes": Array("must-not-write".utf8)])["state"] as? String == "refused"
      wireChecks["crossScopeRefused"] = try request("prepare", ["targetId": targetID], scope: String(repeating: "b", count: 64))["state"] as? String == "refused"
      var wrong = snapshot; wrong["helperInstanceId"] = UUID().uuidString
      wireChecks["snapshotMismatchRefused"] = try request("prepare", ["targetId": targetID, "expected": wrong])["state"] as? String == "refused"
      let newInstance = MacNativeBackgroundWire(profiles: [profile], live: { true })
      let oldTarget = try JSONSerialization.data(withJSONObject: ["format": 1, "command": "prepare", "scope": scopeID, "targetId": targetID])
      let oldReply = try JSONSerialization.jsonObject(with: newInstance.handle(oldTarget)) as! [String: Any]
      wireChecks["lostReferencesNotReconstructed"] = oldReply["state"] as? String == "refused"
      _ = try request("release", ["targetId": targetID]); _ = try request("release", ["targetId": targetID])
      wireChecks["releaseForgetsTarget"] = try request("prepare", ["targetId": targetID])["state"] as? String == "refused"
      ownerAlive = false
      wireChecks["ownerDisconnectRefused"] = try request("discover", ["appId": profile.bundleIdentifier])["state"] as? String == "refused"
      ownerAlive = true
      let disposed = try JSONSerialization.data(withJSONObject: ["format": 1, "command": "dispose"])
      let disposedReply = try JSONSerialization.jsonObject(with: wire.handle(disposed)) as! [String: Any]
      let afterDisposal = try request("discover", ["appId": profile.bundleIdentifier])
      wireChecks["disposeEndsConnectionRegistry"] = disposedReply["state"] as? String == "disposed" && afterDisposal["state"] as? String == "refused"
    }
    wire.close()
    let wirePassed = wireChecks.count == 10 && wireChecks.values.allSatisfy { $0 }
    try save("wire-results.json", ["passed": wirePassed, "checks": wireChecks])
    // Test-only independent foreground typing across the observation interval.
    // This is never linked into the production adapter and is not a fallback.
    try activate("cover", action: "cover")
    let coverPID = (try load("cover-pid.json"))["pid"] as! pid_t
    let baseline = Snapshot()
    let typing = "work-🙂", units = Array(typing.utf16)
    for down in [true, false] {
      let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: 0, keyDown: down)!
      event.flags = []
      units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress!) }
      event.postToPid(coverPID)
    }
    pump(0.3)
    let work = try load("cover-state.json")
    let typed = (work["fields"] as? [String: [String: Bool]])?["field-0-0"]?["workInputMatches"] == true
    try save("foreground-typing.json", ["passed": typed && baseline.same(Snapshot()), "fixture": work])
    let passed = rows.allSatisfy { $0["passed"] as? Bool == true } && typed && wirePassed
    try save("result.json", ["passed": passed, "platformCases": rows.count, "foregroundTypingPassed": typed,
      "formalSignedHelperTCCVerified": false, "productionRPCEnabled": false])
    if !passed { exit(1) }
  }
}
