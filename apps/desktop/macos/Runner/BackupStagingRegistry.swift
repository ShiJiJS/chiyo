import Foundation
import Darwin

protocol BackupSecurityScopes {
  func bookmark(_ url: URL) throws -> Data
  func resolve(_ data: Data) throws -> (URL, Bool)
  func start(_ url: URL) -> Bool
  func stop(_ url: URL)
}

struct SystemBackupSecurityScopes: BackupSecurityScopes {
  func bookmark(_ url: URL) throws -> Data {
    try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
  }
  func resolve(_ data: Data) throws -> (URL, Bool) {
    var stale = false
    let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                      relativeTo: nil, bookmarkDataIsStale: &stale)
    return (url, stale)
  }
  func start(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
  func stop(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

/// Native allocation authority. SQLCipher registers the returned private child
/// before material production. The OS replacement container's parent may be
/// inaccessible (TemporaryItems); all Dart cleanup is beneath that container.
final class BackupStagingRegistry {
  enum Failure: Error { case unavailable(Int32), changed, notEmpty, unknown }
  private struct Identity: Equatable {
    let device: dev_t, inode: ino_t, birthSeconds: Int, birthNanos: Int
    let mode: mode_t
    let generation: UInt32
    var serialized: String { "macos:\(device):\(inode):\(birthSeconds):\(birthNanos):\(generation):\(mode)" }
  }
  private struct Entry {
    let directory: URL, identity: Identity
    var allocation: (URL, Identity)?
    var destination: URL?
    var released = false
  }
  private var entries: [String: Entry] = [:]
  private var selections: [Bool: (path: String, url: URL)] = [:]
  private let scopes: BackupSecurityScopes
  private var leases: [String: [URL]] = [:]

  init(scopes: BackupSecurityScopes = SystemBackupSecurityScopes()) { self.scopes = scopes }
  deinit { for urls in leases.values { for url in urls.reversed() { scopes.stop(url) } } }

  /// Both recovery-key and archive outputs need the same native allocation
  /// authority. Resolve only the parent: an existing final entry is never
  /// followed or replaced by the Dart no-overwrite publisher.
  func selectOutput(_ url: URL, recovery: Bool) throws -> String {
    let parent = try canonicalPath(url.deletingLastPathComponent())
    let path = URL(fileURLWithPath: parent).appendingPathComponent(url.lastPathComponent).path
    selections[recovery] = (path, url)
    return path
  }

  func prepareSelected(_ path: String) throws -> [String: String] {
    guard let selected = selections.first(where: { $0.value.path == path }) else { throw Failure.unknown }
    selections.removeValue(forKey: selected.key)
    return try prepare(for: selected.value.url)
  }

  func inputPath(_ url: URL) throws -> String { try canonicalPath(url) }

  func prepare(for destination: URL) throws -> [String: String] {
    let allocated = try FileManager.default.url(for: .itemReplacementDirectory,
      in: .userDomainMask, appropriateFor: destination, create: true)
    // Foundation resolvingSymlinksInPath may prefer /var over /private/var.
    // Persist the same kernel canonical spelling as Dart's realpath boundary.
    let allocation = URL(fileURLWithPath: try canonicalPath(allocated))
    let child = allocation.appendingPathComponent("backup-operation")
    var registeredToken: String?
    do {
      let fd = open(allocation.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard fd >= 0 else { throw Failure.unavailable(errno) }
      defer { close(fd) }
      let identity = try identify(fd)
      try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      var result = try registerEmpty(child)
      registeredToken = result["token"]!
      entries[result["token"]!]!.allocation = (allocation, identity)
      entries[result["token"]!]!.destination = destination
      // A future output file cannot yet be bookmarked. Its private allocation
      // exists now and must be recoverable before any key/archive is produced.
      result["stagingBookmark"] = try encodeBookmark(allocation)
      return result
    } catch {
      if let token = registeredToken { entries.removeValue(forKey: token) }
      // Never recursive, including a failed allocation/registration.
      _ = rmdir(child.path)
      _ = rmdir(allocation.path)
      throw error
    }
  }

  func outputBookmark(_ token: String) throws -> String {
    guard let destination = entries[token]?.destination else { throw Failure.unknown }
    return try encodeBookmark(destination)
  }

  /// Only an explicit native Open-panel choice may repair missing output
  /// access. It must name the original path; storage still verifies the inode.
  func reselectedOutputBookmark(_ url: URL, expectedPath: String) throws -> String {
    guard try canonicalPath(url) == expectedPath else { throw Failure.changed }
    return try encodeBookmark(url)
  }

  /// Metadata comes only from the Owner's encrypted operation journal. No
  /// mounts, prompts, path fallback, or automatic bookmark renewal occur here.
  func acquireRecordedAccess(_ value: [String: String], needsOutput: Bool) throws -> String {
    guard value.count == 5, let path = value["path"], let expectedParent = value["parentIdentity"],
          let staging = value["stagingBookmark"], let output = value["outputBookmark"],
          let destination = value["destination"], path.hasPrefix("/"), destination.hasPrefix("/") else { throw Failure.changed }
    let allocation = URL(fileURLWithPath: path).deletingLastPathComponent()
    guard allocation.lastPathComponent.hasPrefix("NSIRD_"),
          URL(fileURLWithPath: path).lastPathComponent == "backup-operation" else { throw Failure.changed }
    var acquired: [URL] = []
    do {
      // Cleanup acknowledgement may be retried after the exact allocation has
      // already gone. Permission denial and replacements are not absence.
      var status = stat()
      if !needsOutput && lstat(allocation.path, &status) != 0 && errno == ENOENT {
        let token = UUID().uuidString; leases[token] = []; return token
      }
      let stageURL = try activate(staging)
      acquired.append(stageURL)
      guard try canonicalPath(stageURL) == allocation.path else { throw Failure.changed }
      let fd = open(allocation.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard fd >= 0 else { throw Failure.unavailable(errno) }
      defer { close(fd) }
      guard try identify(fd).serialized == expectedParent else { throw Failure.changed }
      if needsOutput {
        let outputURL = try activate(output)
        acquired.append(outputURL)
        guard try canonicalPath(outputURL) == destination else { throw Failure.changed }
      }
      let token = UUID().uuidString
      leases[token] = acquired
      return token
    } catch {
      for url in acquired.reversed() { scopes.stop(url) }
      throw error
    }
  }

  func releaseAccess(_ token: String) {
    if let urls = leases.removeValue(forKey: token) {
      for url in urls.reversed() { scopes.stop(url) }
    }
  }

  private func encodeBookmark(_ url: URL) throws -> String {
    let data = try scopes.bookmark(url)
    guard !data.isEmpty, data.count <= 65536 else { throw Failure.changed }
    return data.base64EncodedString()
  }
  private func activate(_ text: String) throws -> URL {
    guard text.utf8.count <= 87384, let data = Data(base64Encoded: text), !data.isEmpty,
          data.count <= 65536, data.base64EncodedString() == text else { throw Failure.changed }
    let (url, stale) = try scopes.resolve(data)
    guard !stale, url.isFileURL, scopes.start(url) else { throw Failure.changed }
    return url
  }

  // Internal seam also used by the standalone native lifecycle checks.
  func registerEmpty(_ directory: URL) throws -> [String: String] {
    guard directory.path == (try canonicalPath(directory)) else {
      throw Failure.changed
    }
    let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw Failure.unavailable(errno) }
    defer { close(fd) }
    let identity = try identify(fd)
    guard try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else {
      throw Failure.notEmpty
    }
    let token = UUID().uuidString
    let parent = open(directory.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { throw Failure.unavailable(errno) }
    defer { close(parent) }
    let parentIdentity = try identify(parent)
    entries[token] = Entry(directory: directory, identity: identity)
    return ["directory": directory.path, "token": token, "identity": identity.serialized,
      "parentIdentity": parentIdentity.serialized]
  }

  /// Called only by the Owner adapter with its SQLCipher-registered identity,
  /// never a page/Agent path. This also works after process-local tokens expire.
  func releaseRecorded(_ value: [String: String]) throws {
    guard value.count == 3, let path = value["path"], let expected = value["identity"],
          let expectedParent = value["parentIdentity"], path.hasPrefix("/"), !path.contains("\0") else { throw Failure.changed }
    let child = URL(fileURLWithPath: path), allocation = child.deletingLastPathComponent()
    guard child.lastPathComponent == "backup-operation", allocation.lastPathComponent.hasPrefix("NSIRD_"),
          !path.split(separator: "/").contains(".."),
          !path.split(separator: "/").contains(".") else { throw Failure.changed }
    let parent = open(allocation.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    if parent < 0 { guard errno == ENOENT else { throw Failure.unavailable(errno) }; return }
    defer { close(parent) }
    guard allocation.path == (try canonicalPath(allocation)) else { throw Failure.changed }
    let parentIdentity = try identify(parent)
    guard parentIdentity.serialized == expectedParent else { throw Failure.changed }
    let fd = open(child.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    if fd < 0 { guard errno == ENOENT else { throw Failure.unavailable(errno) } }
    else {
      defer { close(fd) }
      let identity = try identify(fd)
      guard identity.serialized == expected else { throw Failure.changed }
      try removeEmpty(child, identity: identity)
    }
    try removeEmpty(allocation, identity: parentIdentity)
  }

  func release(_ token: String) throws {
    guard var entry = entries[token] else { throw Failure.unknown }
    if entry.released { return }
    try removeEmpty(entry.directory, identity: entry.identity)
    if let (allocation, identity) = entry.allocation { try removeEmpty(allocation, identity: identity) }
    entry.released = true
    entries[token] = entry
  }

  private func removeEmpty(_ directory: URL, identity: Identity) throws {
    let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    if fd < 0 {
      guard errno == ENOENT else { throw Failure.unavailable(errno) }
      return
    }
    defer { close(fd) }
    guard directory.path == (try canonicalPath(directory)),
          try identify(fd) == identity else { throw Failure.changed }
    // rmdir refuses any nonempty directory, even if an entry arrives after the
    // identity check. It never follows a final symlink or recursively removes.
    guard rmdir(directory.path) == 0 else { throw Failure.notEmpty }
  }

  private func identify(_ fd: Int32) throws -> Identity {
    var value = stat()
    guard fstat(fd, &value) == 0, value.st_uid == geteuid(),
          value.st_mode & S_IFMT == S_IFDIR, value.st_mode & 0o777 == 0o700 else { throw Failure.changed }
    return Identity(device: value.st_dev, inode: value.st_ino,
      birthSeconds: value.st_birthtimespec.tv_sec, birthNanos: value.st_birthtimespec.tv_nsec,
      mode: value.st_mode, generation: value.st_gen)
  }

  private func canonicalPath(_ directory: URL) throws -> String {
    guard let resolved = realpath(directory.path, nil) else { throw Failure.unavailable(errno) }
    defer { free(resolved) }
    return String(cString: resolved)
  }
}
