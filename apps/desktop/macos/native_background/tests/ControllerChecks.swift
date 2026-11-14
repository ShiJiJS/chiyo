import Foundation

private final class MockEnvironment: MacNativeBackgroundEnvironment {
  var calls = 0
  var checked = 0
  var changed = false
  var outcome: MacNativeBackgroundWriteResult = .setterAccepted
  var duringCheck: (() -> Void)?
  var duringWrite: (() -> Void)?
  var rotate = false
  let candidate = MacNativeBackgroundCandidate(descriptor: MacNativeBackgroundDescriptor(
    candidateID: UUID(), windowIdentifier: "window", windowTitle: "Synthetic", fieldIdentifier: "a", fieldLabel: "Password"), reference: NSObject())
  func discover(_ application: MacFocusApplication) throws -> [MacNativeBackgroundCandidate] {
    if !rotate { return [candidate] }
    return [MacNativeBackgroundCandidate(descriptor: MacNativeBackgroundDescriptor(candidateID: UUID(),
      windowIdentifier: "window", windowTitle: "Synthetic", fieldIdentifier: "a", fieldLabel: "Password"), reference: NSObject())]
  }
  func recheck(_ candidate: MacNativeBackgroundCandidate) throws {
    checked += 1; duringCheck?()
    if changed { throw MacNativeBackgroundFailure.targetChanged }
  }
  func write(_ secret: String, to candidate: MacNativeBackgroundCandidate,
             authorized: () -> Bool) -> MacNativeBackgroundWriteResult {
    duringWrite?()
    guard authorized() else { return .refused(.unauthorized) }
    calls += 1
    return outcome
  }
}

@main enum ControllerChecks {
  static func main() throws {
    let application = try MacFocusApplication(executable: "/synthetic/app", sha256: String(repeating: "a", count: 64))
    var tests = 0
    func check(_ truth: Bool) { precondition(truth); tests += 1 }
    for result in [MacNativeBackgroundWriteResult.setterAccepted, .unknown] {
      let env = MockEnvironment(); env.outcome = result
      let owner = MacNativeBackgroundAccess(scopeID: UUID(), application: application, isAuthorized: { true })
      let controller = MacNativeBackgroundController(environment: env, connected: { true })
      let candidates = try controller.discover(owner)
      let lease = try controller.capture(candidates[0].candidateID, access: owner)
      check(controller.write(Data(" 假密码🙂e\u{301} ".utf8), lease: lease, access: owner, beforeDispatch: { true }) == result)
      if case .refused = controller.write(Data("different".utf8), lease: lease, access: owner, beforeDispatch: { true }) {} else { preconditionFailure() }
      check(env.calls == 1)
    }
    for mutation in ["revoked", "disconnect", "changed", "expired", "scope", "invalid", "close", "revoke-at-write", "expire-at-write"] {
      let env = MockEnvironment(); var connected = true; var authorized = true; var time: Double = 1
      let owner = MacNativeBackgroundAccess(scopeID: UUID(), application: application, isAuthorized: { authorized })
      let controller = MacNativeBackgroundController(environment: env, connected: { connected }, clock: { time }, discoveryLifetime: 2, preparationLifetime: 2)
      let found = try controller.discover(owner)
      let lease = try controller.capture(found[0].candidateID, access: owner)
      var sending = owner
      switch mutation {
      case "revoked": authorized = false
      case "disconnect": connected = false
      case "changed": env.changed = true
      case "expired": time = 4
      case "scope": sending = MacNativeBackgroundAccess(scopeID: UUID(), application: application, isAuthorized: { true })
      case "close": controller.close()
      case "revoke-at-write": env.duringWrite = { authorized = false }
      case "expire-at-write": env.duringWrite = { time = 4 }
      default: break
      }
      let secret = mutation == "invalid" ? Data([0xff, 0xfe]) : Data("Synthetic-only".utf8)
      if case .refused = controller.write(secret, lease: lease, access: sending, beforeDispatch: { true }) {} else { preconditionFailure(mutation) }
      check(env.calls == 0)
    }
    for value in ["", "line\nbreak", String(repeating: "x", count: 4097)] {
      let env = MockEnvironment()
      let owner = MacNativeBackgroundAccess(scopeID: UUID(), application: application, isAuthorized: { true })
      let controller = MacNativeBackgroundController(environment: env, connected: { true })
      let found = try controller.discover(owner), lease = try controller.capture(found[0].candidateID, access: owner)
      check(controller.write(Data(value.utf8), lease: lease, access: owner, beforeDispatch: { true }) == .refused(.unsupportedSecret))
      check(env.calls == 0)
    }
    // Closing a preparation or consuming its ticket never destroys the target.
    do {
      let env = MockEnvironment(); var time: Double = 1; var grant = true
      let owner = MacNativeBackgroundAccess(scopeID: UUID(), application: application, isAuthorized: { true })
      let controller = MacNativeBackgroundController(environment: env, connected: { true }, clock: { time }, discoveryLifetime: 2, preparationLifetime: 1)
      let target = try controller.discover(owner)[0].candidateID
      try controller.retain(target, until: 20, access: owner, grantIsValid: { grant })
      let cancelled = try controller.capture(target, access: owner)
      controller.closePreparation(cancelled); controller.closePreparation(cancelled)
      time = 4 // Longer than discovery TTL; retained target still valid.
      for _ in 0..<2 {
        let ticket = try controller.capture(target, access: owner)
        check(controller.write(Data("synthetic".utf8), lease: ticket, access: owner, beforeDispatch: { true }) == .setterAccepted)
      }
      let vetoed = try controller.capture(target, access: owner)
      check(controller.write(Data("synthetic".utf8), lease: vetoed, access: owner, beforeDispatch: { false }) == .refused(.unauthorized))
      check(env.calls == 2)
      let expires = try controller.capture(target, access: owner); time = 6
      if case .refused = controller.write(Data("synthetic".utf8), lease: expires, access: owner, beforeDispatch: { true }) {} else { preconditionFailure() }
      _ = try controller.capture(target, access: owner) // Ticket expiry kept target.
      grant = false
      do { _ = try controller.capture(target, access: owner); preconditionFailure() }
      catch { check(env.calls == 2) }
    }
    do {
      let env = MockEnvironment(); env.rotate = true
      let owner = MacNativeBackgroundAccess(scopeID: UUID(), application: application, isAuthorized: { true })
      let controller = MacNativeBackgroundController(environment: env, connected: { true })
      var ids: [UUID] = []
      for _ in 0..<64 { ids.append(try controller.discover(owner)[0].candidateID) }
      do { _ = try controller.discover(owner); preconditionFailure() } catch { check(env.calls == 0) }
      try controller.promote(ids[0], access: owner)
      for _ in 0..<255 {
        let id = try controller.discover(owner)[0].candidateID
        try controller.promote(id, access: owner)
      }
      let overflow = try controller.discover(owner)[0].candidateID
      do { try controller.promote(overflow, access: owner); preconditionFailure() } catch { check(env.calls == 0) }
      do {
        try controller.retain(overflow, until: ProcessInfo.processInfo.systemUptime + 60, access: owner, grantIsValid: { true })
        preconditionFailure()
      } catch { check(env.calls == 0) }
      // Reaching capacity must never evict an already retained target.
      let ticket = try controller.capture(ids[0], access: owner)
      check(controller.write(Data("synthetic".utf8), lease: ticket, access: owner, beforeDispatch: { true }) == .setterAccepted)
    }
    let data = try JSONSerialization.data(withJSONObject: ["checks": tests, "passed": true, "systemInput": false])
    print(String(data: data, encoding: .utf8)!)
  }
}
