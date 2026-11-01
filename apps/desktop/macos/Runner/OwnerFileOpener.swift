import Foundation
import CryptoKit
import Darwin

/// Owner-private native dispatch. It opens only an identity-bound generated
/// attachment in this App's temporary directory, never an arbitrary page URL.
/// The durable caller records `opening` first. This process cache can reconcile
/// a lost channel response; absence after restart never proves no dispatch.
final class OwnerFileOpener {
  enum Failure: Error { case invalid, conflict, busy, changed }
  enum Outcome: String { case pending, opened, notOpened }
  struct Intent: Equatable {
    let operationId: String, digest: String, directory: String, directoryIdentity: String
    let name: String, fileIdentity: String, contentDigest: String
    let byteLength: Int
    init(_ value: [String: Any]) throws {
      guard value.count == 8,
        let id = value["operationId"] as? String, id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil,
        let digest = value["commandDigest"] as? String, digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
        let path = value["path"] as? String, path.utf8.count <= 32768, !path.contains("\0"),
        let directoryIdentity = value["directoryIdentity"] as? String,
        let name = value["name"] as? String, name.range(of: "^attachment\\.[a-z0-9]{1,12}$", options: .regularExpression) != nil,
        let identity = value["fileIdentity"] as? String,
        let content = value["sha256"] as? String, content.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
        let length = value["byteLength"] as? Int, length >= 0, length <= 10 * 1024 * 1024 else { throw Failure.invalid }
      self.operationId = id; self.digest = digest; self.directory = path
      self.directoryIdentity = directoryIdentity; self.name = name; self.fileIdentity = identity
      self.contentDigest = content; self.byteLength = length
    }
  }
  private var entries: [String: (Intent, Outcome)] = [:]
  private let launch: (URL) -> Bool
  init(launch: @escaping (URL) -> Bool) { self.launch = launch }

  /// Called on the main thread, including NSWorkspace dispatch. Bound by 10MiB.
  /// Do not retry a native request whose returned disposition is uncertain.
  func open(_ value: [String: Any]) throws -> Outcome {
    let intent = try Intent(value)
    if let old = entries[intent.operationId] {
      guard old.0 == intent else { throw Failure.conflict }
      return old.1
    }
    // Preserve every accepted id until this App process exits. The persistent
    // journal handles reopens. A bounded cache refuses instead of evict/replay.
    guard entries.count < 256 else { throw Failure.busy }
    try verify(intent)
    entries[intent.operationId] = (intent, .pending)
    let accepted = launch(URL(fileURLWithPath: intent.directory).appendingPathComponent(intent.name))
    let result: Outcome = accepted ? .opened : .notOpened
    entries[intent.operationId] = (intent, result)
    return result
  }
  func status(_ id: String, digest: String) throws -> Outcome? {
    guard let old = entries[id] else { return nil }
    guard old.0.digest == digest else { throw Failure.conflict }
    return old.1
  }
  private func identity(_ fd: Int32, directory: Bool) throws -> String {
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_uid == geteuid(),
      info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
      info.st_mode & 0o7777 == (directory ? 0o700 : 0o600),
      directory || info.st_nlink == 1 else { throw Failure.changed }
    errno = 0
    if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
      defer { acl_free(UnsafeMutableRawPointer(acl)) }
      var entry: acl_entry_t?
      guard acl_valid(acl) == 0, acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1, errno == EINVAL else { throw Failure.changed }
    } else if errno != ENOENT { throw Failure.changed }
    return "macos:\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec):\(info.st_gen)"
  }
  private func canonical(_ path: String) throws -> String {
    guard let result = realpath(path, nil) else { throw Failure.changed }
    defer { free(result) }
    return String(cString: result)
  }
  private func verify(_ value: Intent) throws {
    let dir = URL(fileURLWithPath: value.directory)
    let parent = try canonical(FileManager.default.temporaryDirectory.path)
    guard value.directory.hasPrefix("/"), dir.deletingLastPathComponent().path == parent,
      dir.lastPathComponent.range(of: "^info-managed-[A-Za-z0-9_-]{32}$", options: .regularExpression) != nil,
      try canonical(value.directory) == value.directory else { throw Failure.changed }
    let directory = Darwin.open(value.directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw Failure.changed }
    defer { close(directory) }
    guard try identity(directory, directory: true) == value.directoryIdentity else { throw Failure.changed }
    let file = openat(directory, value.name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard file >= 0 else { throw Failure.changed }
    defer { close(file) }
    guard try identity(file, directory: false) == value.fileIdentity else { throw Failure.changed }
    var hash = SHA256(), count = 0
    var buffer = [UInt8](repeating: 0, count: 65536)
    defer { _ = buffer.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
    while true {
      let n = read(file, &buffer, buffer.count)
      guard n >= 0 else { throw Failure.changed }
      if n == 0 { break }
      count += n
      guard count <= value.byteLength else { throw Failure.changed }
      hash.update(data: Data(buffer.prefix(n)))
    }
    let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
    guard count == value.byteLength, digest == value.contentDigest,
      try identity(file, directory: false) == value.fileIdentity else { throw Failure.changed }
    // Recheck the directory name binding after reading through retained fds.
    let check = Darwin.open(value.directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard check >= 0 else { throw Failure.changed }
    defer { close(check) }
    guard try identity(check, directory: true) == value.directoryIdentity else { throw Failure.changed }
    let current = openat(check, value.name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard current >= 0 else { throw Failure.changed }
    defer { close(current) }
    guard try identity(current, directory: false) == value.fileIdentity else { throw Failure.changed }
  }
}
