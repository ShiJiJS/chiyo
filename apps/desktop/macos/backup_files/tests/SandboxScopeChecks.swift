// Standalone synthetic sandbox acceptance; no panels, UI, SQLCipher or Keychain.
import Foundation
import Darwin

@main struct Probe {
  static func main() throws {
    let bundle = Bundle.main.bundleIdentifier ?? "missing"
    let home = NSHomeDirectory()
    guard bundle.hasPrefix("com.example.infoDesktop.backupScopeQA."), home.contains("/Library/Containers/" + bundle + "/Data") else {
      throw NSError(domain: "ProbeNotContainerized", code: 1)
    }
    guard let canary = ProcessInfo.processInfo.environment["BACKUP_QA_DENIED"] else {
      throw NSError(domain: "MissingSandboxCanary", code: 1)
    }
    do {
      _ = try Data(contentsOf: URL(fileURLWithPath: canary))
      throw NSError(domain: "SandboxOutsideReadUnexpectedlyAllowed", code: 1)
    } catch let error as NSError {
      guard error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError else { throw error }
    }
    print("SANDBOX_OUTSIDE_READ_DENIED")
    let root = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/BackupScopeSynthetic")
    let record = root.appendingPathComponent("record.json")
    let fm = FileManager.default, registry = BackupStagingRegistry()
    if CommandLine.arguments.last == "seed" {
      guard !fm.fileExists(atPath: root.path) else { throw NSError(domain: "SyntheticRootExists", code: 1) }
      try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let output = root.appendingPathComponent("synthetic.txt")
      let selected = try registry.selectOutput(output, recovery: true)
      var value = try registry.prepareSelected(selected)
      try Data([1,2,3]).write(to: output)
      value["outputBookmark"] = try registry.outputBookmark(value["token"]!)
      value["destination"] = selected
      try JSONSerialization.data(withJSONObject: value).write(to: record)
      guard chmod(record.path, 0o600) == 0 else { throw NSError(domain: "PrivateRecord", code: 1) }
      print("SANDBOX_SCOPE_SEED_PASS")
    } else {
      let value = try JSONSerialization.jsonObject(with: Data(contentsOf: record)) as! [String: String]
      let access = ["path": value["directory"]!, "parentIdentity": value["parentIdentity"]!, "stagingBookmark": value["stagingBookmark"]!, "outputBookmark": value["outputBookmark"]!, "destination": value["destination"]!]
      let lease = try registry.acquireRecordedAccess(access, needsOutput: true)
      try registry.releaseRecorded(["path": value["directory"]!, "identity": value["identity"]!, "parentIdentity": value["parentIdentity"]!])
      registry.releaseAccess(lease)
      try fm.removeItem(atPath: value["destination"]!)
      try fm.removeItem(at: record); try fm.removeItem(at: root)
      print("SANDBOX_SCOPE_REOPEN_PASS")
    }
  }
}
