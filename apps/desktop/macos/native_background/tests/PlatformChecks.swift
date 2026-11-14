import AppKit
import ApplicationServices
import Foundation

private func pump(_ seconds: Double) {
  let until = Date().addingTimeInterval(seconds)
  while Date() < until { RunLoop.current.run(until: min(until, Date().addingTimeInterval(0.005))) }
}
private func focus() -> (pid_t, AXUIElement?) {
  let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
  var value: CFTypeRef?
  if pid > 0 { _ = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &value) }
  guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (pid, nil) }
  return (pid, unsafeBitCast(value, to: AXUIElement.self))
}
@main enum PlatformChecks {
  static func main() {
    do { try run() }
    catch { print("platform stopped: " + ((error as? MacNativeBackgroundFailure)?.rawValue ?? "test-harness-error")); exit(2) }
  }
  static func run() throws {
    _ = NSApplication.shared
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    func load(_ name: String) throws -> [String: Any] {
      try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(name))) as! [String: Any]
    }
    func save(_ name: String, _ value: Any) throws {
      try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]).write(to: root.appendingPathComponent(name), options: .atomic)
    }
    func command(_ prefix: String, _ action: String) throws {
      let id = UUID().uuidString
      try save(prefix + "-command.json", ["id": id, "action": action])
      if action == "quit" { pump(0.15); return }
      for _ in 0..<200 {
        pump(0.01)
        if (try? load(prefix + "-ack.json"))?["id"] as? String == id { return }
      }
      throw MacNativeBackgroundFailure.targetUnavailable
    }
    func activate(_ prefix: String, _ action: String = "activate") throws {
      try command(prefix, action)
      let open = Process(); open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      open.arguments = ["-a", root.appendingPathComponent(prefix + ".app").path]
      try open.run(); open.waitUntilExit(); pump(0.2)
    }
    // Test-only metadata capture. Never query AXValue, selected text or content.
    func metadata(_ pid: pid_t) -> [[String: Any]] {
      var output: [[String: Any]] = [], pending = [AXUIElementCreateApplication(pid)]
      while let node = pending.popLast(), output.count < 2048 {
        var row: [String: Any] = [:]
        for name in [kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute] {
          var value: CFTypeRef?
          let status = AXUIElementCopyAttributeValue(node, name as CFString, &value)
          if let text = value as? String { row[name] = text }
          else { row[name] = "status:" + String(status.rawValue) }
        }
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(node, kAXValueAttribute as CFString, &settable)
        row["AXValueSettableStatus"] = status.rawValue; row["AXValueSettable"] = settable.boolValue
        output.append(row)
        for name in [kAXWindowsAttribute, kAXChildrenAttribute] {
          var value: CFTypeRef?
          _ = AXUIElementCopyAttributeValue(node, name as CFString, &value)
          if let children = value as? [AXUIElement], pending.count + children.count + output.count < 2048 { pending.append(contentsOf:children) }
        }
      }
      return output
    }
    let expected = " 新值🔐e\u{301} ! "
    var target: Process?
    let log = FileHandle(forWritingAtPath: root.appendingPathComponent("fixture.log").path)!
    func start(_ identity: String = "target") throws {
      if target?.isRunning == true { try command("target", "quit"); target?.waitUntilExit() }
      for name in ["target-pid.json", "target-state.json", "target-command.json", "target-ack.json"] { try? FileManager.default.removeItem(at: root.appendingPathComponent(name)) }
      try save("case.json", ["expected": expected])
      let process = Process()
      process.executableURL = root.appendingPathComponent(identity + ".app/Contents/MacOS/NativeFixture")
      process.arguments = [root.path]; process.standardOutput = log; process.standardError = log
      try process.run(); target = process
      for _ in 0..<300 {
        pump(0.01)
        if let state = try? load("target-state.json"), state["pid"] as? Int32 == process.processIdentifier { pump(0.2); return }
      }
      throw MacNativeBackgroundFailure.targetUnavailable
    }
    defer { try? command("target", "quit"); try? command("cover", "quit") }
    try start(); try activate("cover", "cover")
    let a = focus(); pump(0.1); let b = focus()
    let stable = a.0 > 0 && a.0 == b.0 && a.1 != nil && b.1 != nil && CFEqual(a.1!, b.1!)
    try command("cover", "focus-b"); pump(0.1); let c = focus()
    let focusChanged = c.0 == a.0 && c.1 != nil && a.1 != nil && !CFEqual(c.1!, a.1!)
    try activate("target"); let d = focus()
    let frontChanged = d.0 != a.0 && d.0 > 0
    try save("calibration.json", ["stable":stable, "focusChanged":focusChanged, "frontChanged":frontChanged])
    guard stable, focusChanged, frontChanged else { throw MacNativeBackgroundFailure.sessionUnavailable }
    var rows: [[String: Any]] = []
    for kind in ["background", "occluded", "minimized", "hidden", "missing-identifiers", "language", "second-identity", "mixed-web", "mixed-wk", "partial-disabled", "partial-readonly", "no-password", "all-disabled", "all-readonly", "web-only", "wk-only", "ambiguous", "rebuild", "close", "restart", "callback-disable", "permission-before", "permission-after", "wrong-file"] {
      let identity = kind == "second-identity" ? "alternate" : "target"
      try start(identity)
      // Both identities are previously unknown to production code. No profile,
      // signature, OS or localization entry is supplied to the environment.
      let appID = "local.chiyo.native-background." + identity
      let env = SystemMacNativeBackgroundEnvironment()
      var permission = true
      let gated = SystemMacNativeBackgroundEnvironment(permission: { permission && AXIsProcessTrusted() })
      let selected = kind.hasPrefix("permission") ? gated : env
      var application = try selected.application(appID)
      if kind == "wrong-file" { application = try MacFocusApplication(executable: application.executable, sha256: String(repeating:"0",count:64)) }
      if kind == "permission-before" { permission = false }
      let action = ["missing-identifiers":"missing-identifiers", "language":"language", "mixed-web":"mixed-web", "mixed-wk":"mixed-wk", "partial-disabled":"disable", "partial-readonly":"readonly", "no-password":"plain", "all-disabled":"disable-all", "all-readonly":"readonly-all", "web-only":"web-only", "wk-only":"wk-only", "ambiguous":"duplicate"][kind]
      if let action { try command("target", action); pump(0.25) }
      try save("ax-metadata-"+kind+".json",metadata(target!.processIdentifier))
      let controller = MacNativeBackgroundController(environment:selected,connected:{true})
      let access = MacNativeBackgroundAccess(scopeID:UUID(),application:application,isAuthorized:{true})
      var found: [MacNativeBackgroundDescriptor] = [], lease: UUID?, result = "not-attempted", error = ""
      do {
        found = try controller.discover(access)
        let chosen = found.first { $0.fieldLabel.contains(kind == "partial-disabled" || kind == "partial-readonly" ? "field-0-1" : "field-0-0") }
        if let chosen { lease = try controller.capture(chosen.candidateID,access:access) }
      } catch let failure as MacNativeBackgroundFailure { error = failure.rawValue }
      if ["rebuild", "close"].contains(kind) { try command("target",kind) }
      if kind == "restart" { try start() }
      if kind == "permission-after" { permission = false }
      try command("target","focus-b")
      if kind == "minimized" { try command("target","minimize"); pump(0.6) }
      if kind == "hidden" { try command("target","hide") }
      try activate("cover",kind == "background" ? "aside" : "cover")
      let normal = ["background","occluded","minimized","hidden","missing-identifiers","language","second-identity","mixed-web","mixed-wk","partial-disabled","partial-readonly"].contains(kind)
      let gate = root.appendingPathComponent("gate-"+kind)
      try FileManager.default.createDirectory(at:gate,withIntermediateDirectories:true)
      var observer: Process?
      if lease != nil {
        let process=Process();process.executableURL=root.appendingPathComponent("observer")
        process.arguments=[root.path,gate.path,"--passive"];process.standardOutput=log;process.standardError=log
        try process.run();observer=process
        for _ in 0..<300 { if FileManager.default.fileExists(atPath:gate.appendingPathComponent("observer-ready").path) { break };pump(0.01) }
        guard FileManager.default.fileExists(atPath:gate.appendingPathComponent("observer-ready").path) else { throw MacNativeBackgroundFailure.sessionUnavailable }
      }
      let begin=ProcessInfo.processInfo.systemUptime
      var noReplay=true
      if let lease {
        switch controller.write(Data(expected.utf8),lease:lease,access:access,beforeDispatch:{
          if kind == "callback-disable" { try? command("target","disable") }
          return true
        }) {
        case .setterAccepted:result="sent"
        case .refused(let why):result="refused:"+why.rawValue
        case .unknown:result="unknown"
        }
        if case .refused = controller.write(Data("must-not-replay".utf8),lease:lease,access:access,beforeDispatch:{true}) {} else {noReplay=false}
      }
      let end=ProcessInfo.processInfo.systemUptime
      var observed=true, covered=true
      if let observer {
        try Data("complete".utf8).write(to:gate.appendingPathComponent("dispatch-completed"),options:.atomic)
        observer.waitUntilExit()
        let evidence = try JSONSerialization.jsonObject(with:Data(contentsOf:gate.appendingPathComponent("observer.json"))) as! [String:Any]
        observed=evidence["observationsPreserved"] as? Bool == true
        let trace=evidence["trace"] as? [[String:Any]] ?? []
        covered=(trace.first?["uptime"] as? Double ?? .infinity) <= begin && (trace.last?["uptime"] as? Double ?? 0) >= end
        try save("observer-"+kind+".json",evidence)
      }
      pump(0.1)
      let fields=(try load("target-state.json"))["fields"] as! [String:[String:Bool]]
      let key=kind == "partial-disabled" || kind == "partial-readonly" ? "field-0-1" : "field-0-0"
      let accepted=fields[key]?["matches"] == true
      let otherUnwritten=fields.filter{$0.key != key}.allSatisfy{$0.value["matches"] != true}
      let discoveryOnly=["no-password","all-disabled","all-readonly","web-only","wk-only","ambiguous","permission-before","wrong-file"].contains(kind)
      let expectedError: [String:String] = ["all-disabled":"unsupportedTarget","web-only":"unsupportedTarget","ambiguous":"ambiguousTarget","permission-before":"permissionRequired","wrong-file":"targetChanged"]
      let passed:Bool
      if discoveryOnly {
        let reason = ["all-readonly","wk-only"].contains(kind) && selected.discoveryExcludedWeb ? "unsupportedTarget" : (expectedError[kind] ?? "")
        passed = found.isEmpty && error == reason && !accepted
      }
      else { passed = lease != nil && observed && covered && noReplay && otherUnwritten && (normal ? accepted && result == "sent" : !accepted && result.hasPrefix("refused:")) }
      rows.append(["case":kind,"passed":passed,"appId":appID,"targets":found.count,"discoveryError":error,"webExcludedDuringDiscovery":selected.discoveryExcludedWeb,"passwordSemanticsDuringDiscovery":selected.discoveryPasswordCount,"result":result,"businessMatched":accepted,"othersUnwritten":otherUnwritten,"noReplay":noReplay,"observationsPreserved":observed,"observerCoversDispatch":covered,"dispatchBegin":begin,"dispatchEnd":end])
      try save("platform-results.json",rows)
      print(kind+": "+(passed ? "passed" : "FAILED")+" "+result+" "+error)
      controller.close()
    }
    // Wire keeps format 1, returns the generic kind, and freezes the exact
    // snapshot. Repeated discovery doesn't turn labels into object authority.
    try save("stage.json",["stage":"wire-begin"])
    try start()
    var alive=true
    let wire=MacNativeBackgroundWire(live:{alive})
    let scope=String(repeating:"a",count:64)
    func request(_ command:String,_ payload:[String:Any]=[:],_ selectedScope:String?=nil)throws->[String:Any]{
      let request:[String:Any] = ["format":1,"command":command,"scope":selectedScope ?? scope].merging(payload){_,b in b}
      return try JSONSerialization.jsonObject(with:wire.handle(JSONSerialization.data(withJSONObject:request))) as! [String:Any]
    }
    var checks:[String:Bool]=[:]
    let discovery=try request("discover",["appId":"local.chiyo.native-background.target"])
    try save("stage.json",["stage":"wire-discovered","response":discovery])
    let targets=discovery["targets"] as? [[String:Any]] ?? []
    checks["genericKindAndFormat"] = discovery["format"] as? Int == 1 && targets.count == 4 && targets.allSatisfy{$0["controlKind"] as? String == "macos_ax_password"}
    if let snapshot=targets.first,let id=snapshot["targetId"] as? String {
      let prepared=try request("prepare",["targetId":id]);let lease=prepared["leaseId"] as? String ?? ""
      _=try request("close",["leaseId":lease])
      checks["closeRetainsTarget"] = try request("prepare",["targetId":id,"expected":snapshot])["state"] as? String == "prepared"
      _=try request("release",["targetId":id])
      checks["releaseInvalidates"] = try request("prepare",["targetId":id])["state"] as? String == "refused"
      checks["crossScopeRefused"] = try request("prepare",["targetId":id],String(repeating:"b",count:64))["state"] as? String == "refused"
      let fresh=MacNativeBackgroundWire(live:{true})
      let old=try JSONSerialization.data(withJSONObject:["format":1,"command":"prepare","scope":scope,"targetId":id])
      checks["helperRestartInvalidates"] = (try JSONSerialization.jsonObject(with:fresh.handle(old)) as! [String:Any])["state"] as? String == "refused"
      fresh.close()
    }
    alive=false
    checks["ownerDisconnectRefused"] = try request("discover",["appId":"local.chiyo.native-background.target"])["state"] as? String == "refused"
    alive=true
    let disposal=try JSONSerialization.data(withJSONObject:["format":1,"command":"dispose"])
    let disposed = try JSONSerialization.jsonObject(with:wire.handle(disposal)) as! [String:Any]
    let afterDisposal = try request("discover",["appId":"local.chiyo.native-background.target"])
    checks["disposeEndsOwner"] = disposed["state"] as? String == "disposed" && afterDisposal["state"] as? String == "refused"
    wire.close()
    // No unbounded strong AX window cache: dropping candidates reclaims every
    // cache entry. Repeat beyond the historical 256 lifetime limit.
    let env=SystemMacNativeBackgroundEnvironment(),app=try env.application("local.chiyo.native-background.target")
    var cacheDiscoveryRetries = 0
    for index in 0..<260 {
      try save("stage.json",["stage":"window-cache-churn","iteration":index])
      try command("target","replace-window"); pump(0.1)
      var ready = false
      // Read-only discovery while the synthetic replacement window settles;
      // there is no setter/replay and the production adapter does not retry.
      for _ in 0..<20 {
        do { let found = try env.discover(app); if found.count == 4 { ready = true; break } }
        catch MacNativeBackgroundFailure.targetUnavailable { cacheDiscoveryRetries += 1 }
        pump(0.05)
      }
      guard ready else { throw MacNativeBackgroundFailure.targetUnavailable }
    }
    checks["windowCacheReclaimsUnretained"] = true
    try save("window-cache.json",["replacements":260,"readOnlyDiscoveryRetries":cacheDiscoveryRetries,"setterCalls":0])
    let wirePassed=checks.count==8 && checks.values.allSatisfy{$0}
    try save("wire-results.json",["passed":wirePassed,"checks":checks])
    try save("result.json",["passed":rows.allSatisfy{$0["passed"] as? Bool == true} && wirePassed,"platformCases":rows.count,"wireChecks":checks.count,"permissionUnchanged":true,"formalSignedHelperTCCVerified":false])
    if !rows.allSatisfy({$0["passed"] as? Bool == true}) || !wirePassed {exit(1)}
  }
}
