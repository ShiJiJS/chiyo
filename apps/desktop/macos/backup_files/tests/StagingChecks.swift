import Foundation
import Darwin

@main
struct StagingChecks {
  static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
  }
  static func refused(_ action: () throws -> Void) {
    do { try action(); fatalError("Expected refusal") } catch {}
  }
  static func recorded(_ allocation: [String: String]) -> [String: String] {
    ["path": allocation["directory"]!, "identity": allocation["identity"]!, "parentIdentity": allocation["parentIdentity"]!]
  }
  static func main() throws {
    let fm = FileManager.default
    if CommandLine.arguments.count == 3 {
      let mode = CommandLine.arguments[1], record = URL(fileURLWithPath: CommandLine.arguments[2])
      if mode == "allocate" {
        let value = try BackupStagingRegistry().prepare(for: record.deletingLastPathComponent().appendingPathComponent("output.txt"))
        try JSONSerialization.data(withJSONObject: recorded(value)).write(to: record)
      } else if mode == "release" {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: record)) as! [String: String]
        try BackupStagingRegistry().releaseRecorded(value)
      } else { fatalError("Unknown explicit probe mode") }
      return
    }
    let root = fm.temporaryDirectory.appendingPathComponent("backup-native-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: root) }
    let picker = BackupStagingRegistry()
    for recovery in [true, false] {
      let selected = try picker.selectOutput(root.appendingPathComponent(recovery ? "key.txt" : "archive.aimbackup"), recovery: recovery)
      require(selected.hasPrefix("/private/"), "Canonical selection path")
      let stage = try picker.prepareSelected(selected)
      refused { _ = try picker.prepareSelected(selected) }
      try BackupStagingRegistry().releaseRecorded(recorded(stage))
    }
    let old = try picker.selectOutput(root.appendingPathComponent("old.txt"), recovery: true)
    _ = try picker.selectOutput(root.appendingPathComponent("new.txt"), recovery: true)
    refused { _ = try picker.prepareSelected(old) }
    let input = root.appendingPathComponent("input.txt")
    try Data([7]).write(to: input)
    let canonicalInput = try picker.inputPath(input)
    require(canonicalInput.hasPrefix("/private/"), "Canonical input path")
    func allocate() throws -> [String: String] {
      try BackupStagingRegistry().prepare(for: root.appendingPathComponent("output.txt"))
    }
    // New registry has no original token; only the exact persisted identities.
    let first = try allocate(), record = recorded(first)
    let child = URL(fileURLWithPath: first["directory"]!)
    try BackupStagingRegistry().releaseRecorded(record)
    require(!fm.fileExists(atPath: child.deletingLastPathComponent().path), "Allocation remains")
    try BackupStagingRegistry().releaseRecorded(record)

    let second = try allocate(), secondChild = URL(fileURLWithPath: second["directory"]!)
    let unknown = secondChild.appendingPathComponent("owner-file")
    try Data([1,2,3]).write(to: unknown)
    refused { try BackupStagingRegistry().releaseRecorded(recorded(second)) }
    require(fm.fileExists(atPath: unknown.path), "Unknown child removed")
    try fm.removeItem(at: unknown)
    require(rmdir(secondChild.path) == 0, "Dart-side child cleanup")
    // Native cleanup still removes its allocation after Dart removed the child.
    try BackupStagingRegistry().releaseRecorded(recorded(second))

    let third = try allocate(), thirdChild = URL(fileURLWithPath: third["directory"]!)
    var forged = recorded(third); forged["parentIdentity"] = "macos:wrong"
    refused { try BackupStagingRegistry().releaseRecorded(forged) }
    require(fm.fileExists(atPath: thirdChild.path), "Changed parent must preserve child")
    let renamed = thirdChild.appendingPathExtension("original")
    try fm.moveItem(at: thirdChild, to: renamed)
    try fm.createDirectory(at: thirdChild, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    refused { try BackupStagingRegistry().releaseRecorded(recorded(third)) }
    try fm.removeItem(at: thirdChild); try fm.moveItem(at: renamed, to: thirdChild)
    let sibling = thirdChild.deletingLastPathComponent().appendingPathComponent("unknown-sibling")
    try Data([4]).write(to: sibling)
    refused { try BackupStagingRegistry().releaseRecorded(recorded(third)) }
    require(fm.fileExists(atPath: sibling.path), "Unknown allocation sibling removed")
    try fm.removeItem(at: sibling)
    try BackupStagingRegistry().releaseRecorded(recorded(third))
    print("PASS: key/archive selection authority; canonical inputs/outputs; replaced/consumed selections; real Foundation allocation; token-free release; repeated release; child already removed; nonempty child; changed parent; replaced child; nonempty allocation")
  }
}
