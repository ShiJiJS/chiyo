import Foundation
import CryptoKit
import Darwin

@main
struct DispatchChecks {
  static func require(_ c: @autoclosure () throws -> Bool) rethrows { let value=try c(); precondition(value) }
  static func refused(_ f: () throws -> Void) { do { try f(); fatalError("Expected refusal") } catch {} }
  static func identity(_ path: String) throws -> String {
    var s = stat(); guard lstat(path, &s) == 0 else { throw OwnerFileOpener.Failure.changed }
    return "macos:\(s.st_dev):\(s.st_ino):\(s.st_birthtimespec.tv_sec):\(s.st_birthtimespec.tv_nsec):\(s.st_gen)"
  }
  static func main() throws {
    let fm = FileManager.default
    let resolved = realpath(fm.temporaryDirectory.path, nil)!
    let temp = URL(fileURLWithPath: String(cString: resolved)); free(resolved)
    let root = temp.appendingPathComponent("info-managed-" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
    try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: root) } // This test's exclusively created synthetic root only.
    let file = root.appendingPathComponent("attachment.txt"), data = Data("synthetic owner open".utf8)
    require(fm.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]))
    var value: [String: Any] = ["operationId": "native-owner-open", "commandDigest": String(repeating: "a", count: 64),
      "path": root.path, "directoryIdentity": try identity(root.path), "name": "attachment.txt",
      "fileIdentity": try identity(file.path), "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), "byteLength": data.count]
    var calls = 0
    let opener = OwnerFileOpener { url in calls += 1; require(url == file); return true }
    try require(try opener.open(value) == .opened)
    try require(try opener.open(value) == .opened); require(calls == 1)
    try require(try opener.status("native-owner-open", digest: String(repeating: "a", count: 64)) == .opened)
    try require(try opener.status("absent", digest: String(repeating: "a", count: 64)) == nil)
    refused { _ = try opener.status("native-owner-open", digest: String(repeating: "b", count: 64)) }
    var changed = value; changed["byteLength"] = data.count + 1
    refused { _ = try opener.open(changed) }; require(calls == 1)
    changed = value; changed["operationId"] = "bad-digest"; changed["sha256"] = String(repeating: "0", count: 64)
    refused { _ = try opener.open(changed) }; require(calls == 1)
    changed = value; changed["operationId"] = "bad-id"; changed["fileIdentity"] = "wrong"
    refused { _ = try opener.open(changed) }
    changed = value; changed["operationId"] = "bad-name"; changed["name"] = "../attachment.txt"
    refused { _ = try opener.open(changed) }
    changed = value; changed["operationId"] = "bad-root"; changed["path"] = temp.path
    refused { _ = try opener.open(changed) }
    changed = value; changed["operationId"] = "bad-length"; changed["byteLength"] = 10 * 1024 * 1024 + 1
    refused { _ = try opener.open(changed) }
    let extra = root.appendingPathComponent("hardlink")
    try fm.linkItem(at: file, to: extra)
    changed = value; changed["operationId"] = "hardlink"
    refused { _ = try opener.open(changed) }; try fm.removeItem(at: extra)
    try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    changed = value; changed["operationId"] = "public-mode"
    refused { _ = try opener.open(changed) }; try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let original = root.appendingPathComponent("original")
    try fm.moveItem(at: file, to: original); try fm.createSymbolicLink(at: file, withDestinationURL: original)
    changed = value; changed["operationId"] = "symlink"
    refused { _ = try opener.open(changed) }; try fm.removeItem(at: file); try fm.moveItem(at: original, to: file)
    var rejectionCalls = 0
    let reject = OwnerFileOpener { _ in rejectionCalls += 1; return false }
    try require(try reject.open(value) == .notOpened); try require(try reject.open(value) == .notOpened); require(rejectionCalls == 1)
    // Private file can be edited in place by a consumer; changed bytes are never
    // accepted for a newly submitted operation, while the old receipt is a fact.
    let handle = try FileHandle(forWritingTo: file); try handle.write(contentsOf: Data("modified".utf8)); try handle.close()
    changed = value; changed["operationId"] = "modified"
    refused { _ = try opener.open(changed) }; try require(try opener.open(value) == .opened); require(calls == 1)
    // Capacity refuses new ids without forgetting any accepted id.
    try data.write(to: file); value["fileIdentity"] = try identity(file.path)
    let bounded = OwnerFileOpener { _ in true }
    for i in 0..<256 { value["operationId"] = "bounded-\(i)"; try require(try bounded.open(value) == .opened) }
    value["operationId"] = "bounded-overflow"; refused { _ = try bounded.open(value) }
    print("OWNER_FILE_DISPATCH_CHECKS: exact bytes/identities, idempotence, conflicts, absence, symlink/hardlink/mode/content refusal, rejection and bounded cache passed; launcher injected, no external App opened")
  }
}
