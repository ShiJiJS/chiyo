import Foundation
import Darwin

private struct CheckFailure: Error { let message: String }
private func check(_ condition: @autoclosure () -> Bool, _ message: String = "assertion") throws {
  if !condition() { throw CheckFailure(message: message) }
}
private let app = try! MacFocusApplication(executable: "/Applications/合成 App.app/Contents/MacOS/Test",
                                          sha256: String(repeating: "a", count: 64))
private func bytes(_ units: [UInt16]) -> Data {
  Data(units.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })
}
private final class FakeGate: MacFocusSerialGate {
  var acquired = 0
  var released = 0
  var busy = false
  var onRelease: (() -> Void)?
  func acquire() throws {
    guard !busy else { throw MacFocusFailure("busy") }
    busy = true
    acquired += 1
  }
  func release() { busy = false; released += 1; onRelease?() }
}
private final class FakeEnvironment: MacFocusEnvironment {
  let target = MacFocusTarget(application: app, reference: NSObject())
  var beforeCapture: (() throws -> Void)?
  var beforeRecheck: (() throws -> Void)?
  var beforePost: (() throws -> MacFocusPosting)?
  var batches: [[UInt16]] = []
  func capture() throws -> MacFocusTarget { try beforeCapture?(); return target }
  func recheck(_ target: MacFocusTarget) throws { try beforeRecheck?() }
  func post(_ units: [UInt16], to target: MacFocusTarget) throws -> MacFocusPosting {
    batches.append(units)
    return try beforePost?() ?? .submitted
  }
}
private final class Fixture {
  let environment = FakeEnvironment()
  let gate = FakeGate()
  var time: TimeInterval = 100
  var connected = true
  lazy var controller = MacFocusedFillController(environment: environment, gate: gate,
    connected: { [unowned self] in self.connected }, clock: { [unowned self] in self.time })
  func prepare() throws -> String {
    let result = controller.prepare(app)
    try check(result.state == "prepared")
    guard let lease = result.lease else { throw CheckFailure(message: "missing lease") }
    return lease
  }
  deinit { controller.close() }
}
private final class ReplyBox {
  var value: MacFocusReply?
}

@main
private enum ControllerChecks {
  static func main() throws {
    var passed: [String] = []
    func scenario(_ name: String, _ body: () throws -> Void) throws {
      do { try body(); passed.append(name) }
      catch { fputs("FAIL: \(name)\n", stderr); throw error }
    }
    try scenario("helper permission replies cannot be confused with target readiness") {
      for status in [MacFocusPermissionStatus(state: "ready"),
                     MacFocusPermissionStatus(state: "permission_required", errorCode: "permission_required"),
                     MacFocusPermissionStatus.unavailable] {
        let encoded = try JSONSerialization.data(withJSONObject: status.wire)
        try check(MacFocusPermissionStatus.decode(encoded)?.state == status.state)
      }
      let target = try JSONSerialization.data(withJSONObject: MacFocusReply(state: "ready", application: app).wire)
      try check(MacFocusPermissionStatus.decode(target) == nil)
      for invalid: [String: Any] in [
        ["format": 1, "platform": "windows", "state": "ready"],
        ["format": 1, "platform": "macos", "state": "ready", "errorCode": "permission_required"],
        ["format": 1, "platform": "macos", "state": "permission_required"],
        ["format": 1, "platform": "macos", "state": "unavailable", "errorCode": "unknown_raw_error"]] {
        let encoded = try JSONSerialization.data(withJSONObject: invalid)
        try check(MacFocusPermissionStatus.decode(encoded) == nil)
      }
    }
    try scenario("permission details keep accessibility and event posting independent") {
      for (ax, events) in [(true, false), (false, true), (true, true), (false, false)] {
        let object: [String: Any] = ["format": 2, "platform": "macos", "state": "checked",
                                     "accessibilityTrusted": ax, "postEventsTrusted": events]
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = MacFocusPermissionDetails.decode(data)
        try check(decoded?.state == "checked" && decoded?.accessibilityTrusted == ax && decoded?.postEventsTrusted == events)
      }
    }
    try scenario("permission details reject extra flags, numeric booleans and mixed failure shapes") {
      let valid: [String: Any] = ["format": 2, "platform": "macos", "state": "checked",
                                 "accessibilityTrusted": true, "postEventsTrusted": false]
      var invalid = [valid.merging(["flags": ["prompt": true]]) { _, b in b },
                     valid.merging(["accessibilityTrusted": 1]) { _, b in b },
                     valid.merging(["postEventsTrusted": 0]) { _, b in b },
                     valid.merging(["applicationPath": "/untrusted.app"]) { _, b in b },
                     valid.merging(["errorCode": "busy"]) { _, b in b },
                     valid.merging(["format": 1]) { _, b in b }]
      var missing = valid
      missing.removeValue(forKey: "postEventsTrusted")
      invalid.append(missing)
      invalid.append(["format": 2, "platform": "macos", "state": "unavailable",
                      "errorCode": "unknown", "accessibilityTrusted": false])
      for value in invalid {
        let encoded = try JSONSerialization.data(withJSONObject: value)
        try check(MacFocusPermissionDetails.decode(encoded) == nil)
      }
      for failure in [MacFocusPermissionDetails.unavailable, .busy] {
        try check(Set(failure.wire.keys) == ["format", "platform", "state", "errorCode"])
        let value = MacFocusPermissionDetails.decode(try JSONSerialization.data(withJSONObject: failure.wire))
        try check(value?.state == "unavailable" && value?.accessibilityTrusted == nil && value?.postEventsTrusted == nil)
      }
    }
    try scenario("permission read is inert and an explicit native request asks only for accessibility") {
      var axReads = 0, eventReads = 0, requests = 0
      let probe = MacFocusPermissionProbe(accessibility: { axReads += 1; return false },
        postEvents: { eventReads += 1; return true }, requestAccessibility: { requests += 1 })
      let read = probe.read(requestNative: false)
      try check(read.accessibilityTrusted == false && read.postEventsTrusted == true)
      try check(axReads == 1 && eventReads == 1 && requests == 0)
      _ = probe.read(requestNative: true)
      try check(axReads == 2 && eventReads == 2 && requests == 1)
    }
    try scenario("application identity is exact and bounded") {
      try check(app.wire.count == 2)
      for sha in [String(repeating: "a", count: 64) + "\n", String(repeating: "A", count: 64), "123"] {
        do { _ = try MacFocusApplication(executable: app.executable, sha256: sha); throw CheckFailure(message: "accepted digest") }
        catch is MacFocusFailure {}
      }
      for path in ["C:\\Test.exe", "//host/Test", "/", "/Test/", "/Test\n"] {
        do { _ = try MacFocusApplication(executable: path, sha256: app.sha256); throw CheckFailure(message: "accepted path") }
        catch is MacFocusFailure {}
      }
    }
    try scenario("discovery returns public identity without input or a retained gate") {
      let f = Fixture()
      let result = f.controller.inspect()
      try check(result.state == "ready" && result.application == app && result.lease == nil)
      try check(f.environment.batches.isEmpty && f.gate.acquired == 1 && f.gate.released == 1)
      try check(Set(result.wire.keys) == ["format", "state", "application"])
    }
    try scenario("prepare binds the exact approved path and digest") {
      let f = Fixture()
      let other = try MacFocusApplication(executable: app.executable.lowercased(), sha256: app.sha256)
      let reply = f.controller.prepare(other)
      try check(reply.state == "refused" && reply.errorCode == "application_changed")
      try check(f.environment.batches.isEmpty && !f.gate.busy)
    }
    try scenario("gate is nonqueued and close releases it once") {
      let f = Fixture()
      _ = try f.prepare()
      try check(f.controller.inspect().errorCode == "busy")
      try check(f.controller.prepare(app).errorCode == "busy")
      f.controller.close()
      f.controller.close()
      try check(f.gate.acquired == 1 && f.gate.released == 1)
      try check(f.controller.inspect().errorCode == "session_unavailable")
    }
    try scenario("Unicode batches preserve units and private sequence prevents replay") {
      let f = Fixture()
      let lease = try f.prepare()
      let units = Array("合成🦊".utf16)
      try check(f.controller.send(bytes(units), lease: lease, sequence: 0).state == "sent")
      try check(f.controller.send(bytes([66]), lease: lease, sequence: 0).state == "sent")
      try check(f.environment.batches == [units])
      try check(f.controller.send(bytes(units), lease: lease, sequence: 1).state == "sent")
      try check(f.environment.batches == [units, units])
      try check(f.controller.send(bytes([67]), lease: lease, sequence: 3).state == "partial")
      try check(!f.gate.busy && f.environment.batches.count == 2)
    }
    try scenario("unknown lease cannot cancel the prepared target") {
      let f = Fixture()
      let lease = try f.prepare()
      try check(f.controller.send(bytes([65]), lease: "wrong", sequence: 0).state == "refused")
      try check(f.gate.busy)
      try check(f.controller.send(bytes([65]), lease: lease, sequence: 0).state == "sent")
    }
    try scenario("reject malformed batches before posting") {
      let cases = [Data(), Data([1]), bytes(Array(repeating: 65, count: 17)),
                   bytes([0]), bytes([9]), bytes([10]), bytes([31]), bytes([127]),
                   bytes([0xd800]), bytes([0xdc00]), bytes([0xd800, 65])]
      for data in cases {
        let f = Fixture()
        let lease = try f.prepare()
        let reply = f.controller.send(data, lease: lease, sequence: 0)
        try check(reply.state == "refused" && reply.errorCode == "unsupported_secret")
        try check(f.environment.batches.isEmpty && !f.gate.busy)
      }
    }
    try scenario("target changes before input refuse and after a batch preserve partial") {
      for alreadySent in [false, true] {
        let f = Fixture()
        let lease = try f.prepare()
        if alreadySent { _ = f.controller.send(bytes([65]), lease: lease, sequence: 0) }
        f.environment.beforeRecheck = { throw MacFocusFailure("focus_changed") }
        let reply = f.controller.send(bytes([66]), lease: lease, sequence: alreadySent ? 1 : 0)
        try check(reply.state == (alreadySent ? "partial" : "refused") && reply.errorCode == "focus_changed")
        try check(f.environment.batches.count == (alreadySent ? 1 : 0) && !f.gate.busy)
      }
    }
    try scenario("ambiguous posting closes the lease and cannot replay") {
      for throwing in [false, true] {
        let f = Fixture()
        let lease = try f.prepare()
        f.environment.beforePost = {
          if throwing { throw CheckFailure(message: "synthetic post failure") }
          return .unknown
        }
        let reply = f.controller.send(bytes([65]), lease: lease, sequence: 0)
        try check(reply.state == "unknown" && reply.errorCode == "fill_unknown")
        try check(f.controller.send(bytes([65]), lease: lease, sequence: 0).state == "refused")
        try check(f.environment.batches.count == 1 && !f.gate.busy)
        try check(Set(reply.wire.keys) == ["format", "state", "errorCode"])
      }
    }
    try scenario("unapproved native errors are sanitized") {
      let f = Fixture()
      f.environment.beforeCapture = { throw MacFocusFailure("RAW_PRIVATE_DETAIL") }
      let reply = f.controller.inspect()
      try check(reply.errorCode == "unsupported_target" && !f.gate.busy)
      f.environment.beforeCapture = nil
      let lease = try f.prepare()
      f.environment.beforePost = { .refused("RAW_PRIVATE_DETAIL") }
      try check(f.controller.send(bytes([65]), lease: lease, sequence: 0).errorCode == "unsupported_target")
    }
    try scenario("monotonic expiry and backwards time stop unused batches") {
      for time in [99.0, 160.0] {
        let f = Fixture()
        let lease = try f.prepare()
        f.time = time
        try check(f.controller.send(bytes([65]), lease: lease, sequence: 0).state == "refused")
        try check(f.environment.batches.isEmpty && !f.gate.busy)
      }
    }
    try scenario("disconnect closes a lease without posting") {
      let f = Fixture()
      let lease = try f.prepare()
      f.connected = false
      try check(f.controller.send(bytes([65]), lease: lease, sequence: 0).errorCode == "session_unavailable")
      try check(f.environment.batches.isEmpty && !f.gate.busy)
    }
    try scenario("slow capture cannot prepare a future target") {
      let f = Fixture()
      f.environment.beforeCapture = { f.time += 4 }
      try check(f.controller.prepare(app).errorCode == "session_unavailable")
      try check(f.environment.batches.isEmpty && !f.gate.busy)
    }
    try scenario("close cancels an in-flight capture") {
      let f = Fixture()
      let started = DispatchSemaphore(value: 0)
      let resume = DispatchSemaphore(value: 0)
      let done = DispatchSemaphore(value: 0)
      let result = ReplyBox()
      f.environment.beforeCapture = { started.signal(); _ = resume.wait(timeout: .now() + 2) }
      DispatchQueue.global().async { result.value = f.controller.prepare(app); done.signal() }
      try check(started.wait(timeout: .now() + 2) == .success)
      f.controller.close()
      resume.signal()
      try check(done.wait(timeout: .now() + 2) == .success)
      try check(result.value?.errorCode == "session_unavailable" && !f.gate.busy)
      try check(f.gate.acquired == 1 && f.gate.released == 1 && f.environment.batches.isEmpty)
    }
    try scenario("concurrent duplicate batches post once after rechecking") {
      let f = Fixture()
      let lease = try f.prepare()
      let started = DispatchSemaphore(value: 0)
      let resume = DispatchSemaphore(value: 0)
      let done = DispatchGroup()
      f.environment.beforeRecheck = { started.signal(); _ = resume.wait(timeout: .now() + 2) }
      for _ in 0..<2 {
        done.enter()
        DispatchQueue.global().async {
          _ = f.controller.send(bytes([65]), lease: lease, sequence: 0)
          done.leave()
        }
      }
      try check(started.wait(timeout: .now() + 2) == .success)
      try check(started.wait(timeout: .now() + 2) == .success)
      resume.signal()
      resume.signal()
      try check(done.wait(timeout: .now() + 2) == .success)
      try check(f.environment.batches.count == 1)
    }
    try scenario("idle lease automatically releases the global gate") {
      let environment = FakeEnvironment()
      let gate = FakeGate()
      let released = DispatchSemaphore(value: 0)
      gate.onRelease = { released.signal() }
      let controller = MacFocusedFillController(environment: environment, gate: gate,
        connected: { true }, lifetime: 0.03)
      let lease = controller.prepare(app).lease!
      try check(released.wait(timeout: .now() + 2) == .success)
      try check(controller.send(bytes([65]), lease: lease, sequence: 0).state == "refused")
      try check(environment.batches.isEmpty && gate.released == 1)
    }
    try scenario("real private file gate excludes a second instance and refuses aliases") {
      let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      defer { try? FileManager.default.removeItem(at: root) }
      let a = MacFocusFileGate(base: root)
      let b = MacFocusFileGate(base: root)
      try a.acquire()
      do { try b.acquire(); throw CheckFailure(message: "second gate acquired") }
      catch let failure as MacFocusFailure { try check(failure.code == "busy") }
      a.release()
      try b.acquire()
      b.release()
      let folder = root.appendingPathComponent("org.shijijs.agent-info-manage.focused-fill")
      let file = folder.appendingPathComponent("input.lock")
      try FileManager.default.removeItem(at: file)
      try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("unknown"))
      do { try a.acquire(); throw CheckFailure(message: "alias accepted") }
      catch let failure as MacFocusFailure { try check(failure.code == "access_denied") }
      try FileManager.default.removeItem(at: file)
      _ = FileManager.default.createFile(atPath: file.path, contents: Data(), attributes: [.posixPermissions: 0o644])
      do { try a.acquire(); throw CheckFailure(message: "broad permissions accepted") }
      catch let failure as MacFocusFailure { try check(failure.code == "access_denied") }
    }
    let report: [String: Any] = ["kind": "headless-native-controller", "passed": passed.count,
      "scenarios": passed, "systemAXExecuted": false, "inputEventsPosted": false]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
  }
}
