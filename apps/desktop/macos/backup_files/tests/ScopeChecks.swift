import Foundation
import Darwin

final class FakeBackupScopes: BackupSecurityScopes {
  var urls: [Data: URL] = [:]
  var stale = false, denied = false, started = 0, stopped = 0
  func bookmark(_ url: URL) throws -> Data {
    let data = Data(UUID().uuidString.utf8); urls[data] = url; return data
  }
  func resolve(_ data: Data) throws -> (URL, Bool) {
    guard let url = urls[data] else { throw BackupStagingRegistry.Failure.unknown }
    return (url, stale)
  }
  func start(_ url: URL) -> Bool { if denied { return false }; started += 1; return true }
  func stop(_ url: URL) { stopped += 1 }
}

@main
struct ScopeChecks {
  static func require(_ value: @autoclosure () -> Bool) { precondition(value()) }
  static func refused(_ action: () throws -> Void) {
    do { try action(); fatalError("Expected refusal") } catch {}
  }
  static func main() throws {
    let fm = FileManager.default
    if CommandLine.arguments.count == 3 {
      let mode = CommandLine.arguments[1], recordURL = URL(fileURLWithPath: CommandLine.arguments[2])
      let registry = BackupStagingRegistry()
      if mode == "seed" {
        let output = recordURL.deletingLastPathComponent().appendingPathComponent("synthetic-output.txt")
        let selected = try registry.selectOutput(output, recovery: true)
        var value = try registry.prepareSelected(selected)
        try Data([1, 2, 3]).write(to: output)
        value["outputBookmark"] = try registry.outputBookmark(value["token"]!)
        value["destination"] = selected
        try JSONSerialization.data(withJSONObject: value).write(to: recordURL)
        require(chmod(recordURL.path, 0o600) == 0)
      } else if mode == "recover" {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as! [String: String]
        let access = ["path": value["directory"]!, "parentIdentity": value["parentIdentity"]!,
          "stagingBookmark": value["stagingBookmark"]!, "outputBookmark": value["outputBookmark"]!, "destination": value["destination"]!]
        let lease = try registry.acquireRecordedAccess(access, needsOutput: true)
        try registry.releaseRecorded(["path": value["directory"]!, "identity": value["identity"]!, "parentIdentity": value["parentIdentity"]!])
        registry.releaseAccess(lease)
        try fm.removeItem(atPath: value["destination"]!)
      } else { fatalError("Unknown probe mode") }
      print("PASS: real Foundation bookmark process \(mode)")
      return
    }
    let root = fm.temporaryDirectory.appendingPathComponent("backup-scope-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: root) }
    let scopes = FakeBackupScopes(), registry = BackupStagingRegistry(scopes: scopes)
    let output = root.appendingPathComponent("original.txt")
    let selected = try registry.selectOutput(output, recovery: true)
    let allocation = try registry.prepareSelected(selected)
    let record = ["path": allocation["directory"]!, "identity": allocation["identity"]!, "parentIdentity": allocation["parentIdentity"]!]
    defer { try? registry.releaseRecorded(record) }
    try Data([1]).write(to: output)
    let outputBookmark = try registry.outputBookmark(allocation["token"]!)
    var access = ["path": allocation["directory"]!, "parentIdentity": allocation["parentIdentity"]!,
      "stagingBookmark": allocation["stagingBookmark"]!, "outputBookmark": outputBookmark, "destination": selected]
    // A fresh registry proves leases do not depend on old in-memory tokens.
    var reopened: BackupStagingRegistry? = BackupStagingRegistry(scopes: scopes)
    let lease = try reopened!.acquireRecordedAccess(access, needsOutput: true)
    require(scopes.started == 2 && scopes.stopped == 0)
    reopened!.releaseAccess(lease); reopened!.releaseAccess(lease)
    require(scopes.stopped == 2)
    scopes.stale = true
    refused { _ = try reopened!.acquireRecordedAccess(access, needsOutput: true) }
    require(scopes.started == scopes.stopped)
    scopes.stale = false; scopes.denied = true
    refused { _ = try reopened!.acquireRecordedAccess(access, needsOutput: true) }
    require(scopes.started == scopes.stopped)
    scopes.denied = false
    access["outputBookmark"] = ""
    refused { _ = try reopened!.acquireRecordedAccess(access, needsOutput: true) }
    require(scopes.started == scopes.stopped) // Partial stage lease released.
    let stageOnly = try reopened!.acquireRecordedAccess(access, needsOutput: false)
    reopened!.releaseAccess(stageOnly)
    access["outputBookmark"] = outputBookmark
    access["parentIdentity"] = "changed"
    refused { _ = try reopened!.acquireRecordedAccess(access, needsOutput: true) }
    require(scopes.started == scopes.stopped)
    access["parentIdentity"] = allocation["parentIdentity"]!
    access["destination"] = selected + ".wrong"
    refused { _ = try reopened!.acquireRecordedAccess(access, needsOutput: true) }
    require(scopes.started == scopes.stopped)
    refused { _ = try registry.reselectedOutputBookmark(output, expectedPath: selected + ".wrong") }
    access["destination"] = selected
    access["outputBookmark"] = try registry.reselectedOutputBookmark(output, expectedPath: selected)
    _ = try reopened!.acquireRecordedAccess(access, needsOutput: true)
    reopened = nil // Outstanding leases released on lifecycle end.
    require(scopes.started == scopes.stopped)
    try registry.releaseRecorded(record)
    let cleanup = BackupStagingRegistry(scopes: scopes)
    let absent = try cleanup.acquireRecordedAccess(access, needsOutput: false)
    cleanup.releaseAccess(absent)
    refused { _ = try cleanup.acquireRecordedAccess(access, needsOutput: true) }
    require(scopes.started == scopes.stopped)
    print("PASS: persisted allocation/output scopes; balanced leases; stale/denied/partial failure; parent/path mismatch; explicit exact selection; lifecycle release; removed allocation cleanup only")
  }
}
