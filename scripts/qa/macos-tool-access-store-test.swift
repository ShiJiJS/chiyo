import Foundation
import Darwin

// Tests production persistence/rollback with a controlled scope adapter.
// This is NOT evidence of an owner-granted macOS sandbox extension.
private final class Scopes: ToolDirectoryScopes {
  var stale = false
  var denied = false
  var oversized = false
  var active = 0
  var starts = 0
  var stops = 0
  var permissions: [ToolDirectoryPermission] = []
  func bookmark(_ url: URL, permission: ToolDirectoryPermission) throws -> Data {
    permissions.append(permission)
    return oversized ? Data(repeating: 1, count: 65537) : Data(url.path.utf8)
  }
  func resolve(_ data: Data) throws -> (URL, Bool) {
    (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale)
  }
  func start(_ url: URL) -> Bool {
    if denied { return false }
    starts += 1
    active += 1
    return true
  }
  func stop(_ url: URL) { stops += 1; active -= 1; precondition(active >= 0) }
}

private struct TestFailure: Error { let message: String }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !value() { throw TestFailure(message: message) }
}
private func rejects(_ code: String, _ body: () throws -> Void) throws {
  do { try body() }
  catch let error as ToolAccessFailure {
    try check(error.code == code, "wrong failure code")
    return
  }
  throw TestFailure(message: "expected rejection")
}
private func rows(_ store: ToolAccessStore) -> [[String: Any]] {
  store.snapshot()["directories"] as! [[String: Any]]
}

@main
private struct Probe {
  static func main() throws {
    guard CommandLine.arguments.count == 2 else {
      throw TestFailure(message: "Pass a NEW test-owned output directory")
    }
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let fm = FileManager.default
    try check(!fm.fileExists(atPath: root.path), "output already exists")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("外部 工具")
    let second = root.appendingPathComponent("second")
    for directory in [source, second] {
      try fm.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    let payload = source.appendingPathComponent("keep.txt")
    try Data("owned fixture".utf8).write(to: payload)
    var passed: [String] = []
    func test(_ name: String, _ body: () throws -> Void) throws {
      try body()
      passed.append(name)
      print("PASS \(name)")
      fflush(stdout)
    }
    let archive = root.appendingPathComponent("private/directories.json")
    let scopes = Scopes()
    var store: ToolAccessStore? = ToolAccessStore(file: archive, scopes: scopes)
    try test("legacy read-only archive is restored without rewriting or recreating tokens") {
      store = nil
      let legacy: [String: Any] = ["version": 1, "entries": [[
        "id": UUID().uuidString, "path": source.path,
        "bookmark": Data(source.path.utf8).base64EncodedString()
      ]]]
      let data = try JSONSerialization.data(withJSONObject: legacy)
      try fm.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: archive)
      store = ToolAccessStore(file: archive, scopes: scopes)
      try check(!store!.loadFailed && rows(store!).first!["permission"] as? String == "readOnly", "legacy range broadened")
      try check(try Data(contentsOf: archive) == data && scopes.permissions.isEmpty, "legacy token recreated")
      try store!.rememberSelection(second, permission: .readWrite)
      let upgraded = try JSONSerialization.jsonObject(with: Data(contentsOf: archive)) as! [String: Any]
      try check(upgraded["version"] as? Int == 2, "missing version boundary")
      let entries = upgraded["entries"] as! [[String: Any]]
      try check(entries.first!["bookmark"] as? String == Data(source.path.utf8).base64EncodedString(), "legacy bookmark changed")
      try check(entries.map { $0["permission"] as! String } == ["readOnly", "readWrite"], "migration changed ranges")
      try check(scopes.permissions == [.readWrite], "migration requested new read-only token")
      for entry in rows(store!) { try store!.forget(entry["id"] as! String) }
    }
    try test("explicit range survives restart; failed range change retains saved token and scope") {
      try store!.rememberSelection(source, permission: .readWrite)
      let id = rows(store!).first!["id"] as! String
      store = nil
      store = ToolAccessStore(file: archive, scopes: scopes)
      try check(rows(store!).first!["permission"] as? String == "readWrite", "read-write range lost")
      let before = try Data(contentsOf: archive)
      scopes.denied = true
      try rejects("tool_access_unavailable") {
        try store!.rememberSelection(source, replacing: id, permission: .readOnly)
      }
      scopes.denied = false
      try check(try Data(contentsOf: archive) == before && scopes.active == 1, "failed downgrade mutated scope")
      try store!.rememberSelection(source, replacing: id, permission: .readOnly)
      try check(rows(store!).first!["permission"] as? String == "readOnly" && rows(store!).first!["id"] as? String == id, "range change changed identity")
      store = nil
      store = ToolAccessStore(file: archive, scopes: scopes)
      try check(rows(store!).first!["permission"] as? String == "readOnly", "range change not persisted")
      try store!.forget(id)
    }
    try test("save, deduplicate, private permissions and no bookmark response") {
      try check(rows(store!).isEmpty, "expected empty")
      try store!.rememberSelection(source)
      let id = rows(store!).first!["id"] as! String
      try store!.rememberSelection(source)
      try check(rows(store!).count == 1 && rows(store!).first!["id"] as? String == id,
                "duplicate changed identity")
      try check(scopes.active == 1, "duplicate leaked scope")
      try check(rows(store!).first!["bookmark"] == nil, "bookmark escaped")
      let mode = try fm.attributesOfItem(atPath: archive.path)[.posixPermissions] as! NSNumber
      try check(mode.intValue == 0o600, "archive mode")
    }
    try test("reopen restores, deinit balances access") {
      store = nil
      try check(scopes.active == 0, "deinit leaked scope")
      store = ToolAccessStore(file: archive, scopes: scopes)
      try check(rows(store!).first!["available"] as? Bool == true, "not restored")
      try check(scopes.active == 1, "missing scope")
    }
    try test("failed save/remove preserves previous archive and active entry") {
      let original = try Data(contentsOf: archive)
      let backup = archive.appendingPathExtension("test-backup")
      try fm.moveItem(at: archive, to: backup)
      try fm.createDirectory(at: archive, withIntermediateDirectories: false)
      defer {
        try? fm.removeItem(at: archive)
        try? fm.moveItem(at: backup, to: archive)
      }
      let id = rows(store!).first!["id"] as! String
      try rejects("tool_access_storage_failed") { try store!.rememberSelection(second, replacing: id) }
      try rejects("tool_access_storage_failed") { try store!.forget(id) }
      try check(rows(store!).count == 1 && rows(store!).first!["path"] as? String == source.path,
                "failed write mutated model")
      try check(scopes.active == 1, "failed write leaked or stopped scope")
      let saved = try Data(contentsOf: backup)
      try check(saved == original, "previous archive changed")
      let remnants = try fm.contentsOfDirectory(atPath: archive.deletingLastPathComponent().path)
      try check(!remnants.contains(where: { $0.hasPrefix(".tool-access-") }), "temp leaked")
    }
    try test("stale and denied bookmarks require reselect without deleting records") {
      store = nil
      let original = try Data(contentsOf: archive)
      scopes.stale = true
      store = ToolAccessStore(file: archive, scopes: scopes)
      try check(rows(store!).first!["available"] as? Bool == false, "stale accepted")
      try check(!store!.loadFailed && scopes.active == 0, "stale corrupted archive")
      store = nil
      scopes.stale = false
      scopes.denied = true
      store = ToolAccessStore(file: archive, scopes: scopes)
      try check(rows(store!).first!["available"] as? Bool == false, "denied accepted")
      try check(try Data(contentsOf: archive) == original, "unavailable record overwritten")
      scopes.denied = false
      let id = rows(store!).first!["id"] as! String
      try store!.rememberSelection(source, replacing: id)
      try check(rows(store!).first!["available"] as? Bool == true, "reselect failed")
      try check(rows(store!).first!["id"] as? String == id, "reselect changed id")
    }
    try test("duplicate replacement and oversized bookmark preserve active entries") {
      try store!.rememberSelection(second)
      let id = rows(store!).first!["id"] as! String
      try rejects("tool_access_duplicate") { try store!.rememberSelection(second, replacing: id) }
      scopes.oversized = true
      try rejects("tool_access_unavailable") { try store!.rememberSelection(source) }
      scopes.oversized = false
      try check(scopes.active == 2 && rows(store!).count == 2, "rejected selection changed state")
    }
    try test("missing directory is unavailable and releases active scope") {
      try fm.removeItem(at: second)
      try check(rows(store!).last!["available"] as? Bool == false, "missing directory accepted")
      try check(scopes.active == 1, "missing scope not released")
    }
    try test("forget persists across reopen without deleting selected files") {
      for entry in rows(store!) { try store!.forget(entry["id"] as! String) }
      try check(scopes.active == 0, "forget leaked scope")
      store = nil
      store = ToolAccessStore(file: archive, scopes: scopes)
      try check(rows(store!).isEmpty, "forgotten entries restored")
      try check(fm.fileExists(atPath: payload.path), "selected file deleted")
    }
    try test("unknown or incomplete range formats fail closed and preserve archive") {
      store = nil
      for (version, permission) in [(2, "missing"), (2, "unknown"), (1, "readWrite"), (3, "readOnly")] {
        var entry: [String: Any] = ["id": UUID().uuidString, "path": source.path,
                                  "bookmark": Data(source.path.utf8).base64EncodedString()]
        if permission != "missing" { entry["permission"] = permission }
        let data = try JSONSerialization.data(withJSONObject: ["version": version, "entries": [entry]])
        try data.write(to: archive)
        store = ToolAccessStore(file: archive, scopes: scopes)
        try check(store!.loadFailed && scopes.active == 0, "invalid range accepted")
        try rejects("tool_access_storage_failed") { try store!.rememberSelection(source, permission: .readWrite) }
        try check(try Data(contentsOf: archive) == data, "invalid range archive overwritten")
        store = nil
      }
    }
    try test("corrupt archive is retained and cannot be overwritten") {
      store = nil
      let corrupt = Data("invalid archive".utf8)
      try corrupt.write(to: archive)
      store = ToolAccessStore(file: archive, scopes: scopes)
      try check(store!.loadFailed, "corruption not reported")
      try rejects("tool_access_storage_failed") { try store!.rememberSelection(source) }
      try check(try Data(contentsOf: archive) == corrupt, "corrupt archive overwritten")
    }
    try test("symlink archive is refused without changing target") {
      store = nil
      try fm.removeItem(at: archive)
      try fm.createSymbolicLink(at: archive, withDestinationURL: payload)
      store = ToolAccessStore(file: archive, scopes: scopes)
      try check(store!.loadFailed, "symlink accepted")
      try rejects("tool_access_storage_failed") { try store!.rememberSelection(source) }
      try check(try Data(contentsOf: payload) == Data("owned fixture".utf8), "target changed")
    }
    store = nil
    try check(scopes.active == 0 && scopes.starts == scopes.stops, "final scope leak")
    let report: [String: Any] = [
      "scope": "production store with controlled OS scope adapter; not sandbox grant evidence",
      "passed": passed, "failed": 0, "balancedScopeCalls": true
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: root.appendingPathComponent("result.json"))
  }
}
