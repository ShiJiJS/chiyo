import Foundation
import Darwin

@main struct BackupStagingChecks {
  static func check(_ ok: @autoclosure () -> Bool, _ message: String) throws {
    if !ok() { throw NSError(domain: message, code: 1) }
  }
  static var stage = "start"
  static func main() {
    do { try run() } catch {
      FileHandle.standardError.write(Data("FAIL stage=\(stage) errno=\(errno) error=\(error)\n".utf8))
      exit(1)
    }
  }
  static func run() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("backup-staging-check-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: root) }
    let registry = BackupStagingRegistry()
    stage = "prepare"
    let result = try registry.prepare(for: root.appendingPathComponent("output.aimbackup"))
    let directory = URL(fileURLWithPath: result["directory"]!)
    let token = result["token"]!
    defer { try? fm.removeItem(at: directory) }
    stage = "nonempty"
    let unexpected = directory.appendingPathComponent("keep.txt")
    try Data("synthetic".utf8).write(to: unexpected)
    do { try registry.release(token); throw NSError(domain: "nonempty cleanup claimed success", code: 1) }
    catch BackupStagingRegistry.Failure.notEmpty { }
    try check(fm.fileExists(atPath: unexpected.path), "unknown file deleted")
    stage = "retry-empty"
    try fm.removeItem(at: unexpected)
    try registry.release(token)
    try registry.release(token)
    try check(!fm.fileExists(atPath: directory.path), "empty directory retained")

    stage = "replacement"
    let reserved = root.appendingPathComponent("reserved")
    try fm.createDirectory(at: reserved, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let registered = try registry.registerEmpty(reserved)
    let moved = root.appendingPathComponent("moved")
    try fm.moveItem(at: reserved, to: moved)
    try fm.createDirectory(at: reserved, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    do { try registry.release(registered["token"]!); throw NSError(domain: "replacement removed", code: 1) }
    catch BackupStagingRegistry.Failure.changed { }
    try check(fm.fileExists(atPath: reserved.path), "replacement not preserved")
    try fm.removeItem(at: reserved)
    try fm.moveItem(at: moved, to: reserved)
    try registry.release(registered["token"]!)

    stage = "already-cleaned"
    let absent = root.appendingPathComponent("already-cleaned")
    try fm.createDirectory(at: absent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let lease = try registry.registerEmpty(absent)
    try fm.removeItem(at: absent)
    try registry.release(lease["token"]!)
    do { try registry.release("unknown"); throw NSError(domain: "unknown token accepted", code: 1) }
    catch BackupStagingRegistry.Failure.unknown { }
    print("PASS native allocation, nonempty failure/retry, duplicate release, replacement refusal, already-cleaned acknowledgement, unknown token")
  }
}
