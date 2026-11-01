import Foundation
import Darwin

/// Native allocation authority. SQLCipher registers the returned private child
/// before material production. The OS replacement container's parent may be
/// inaccessible (TemporaryItems); all Dart cleanup is beneath that container.
final class BackupStagingRegistry {
  enum Failure: Error { case unavailable(Int32), changed, notEmpty, unknown }
  private struct Identity: Equatable {
    let device: dev_t, inode: ino_t, birthSeconds: Int, birthNanos: Int
    let mode: mode_t
  }
  private struct Entry {
    let directory: URL, identity: Identity
    var allocation: (URL, Identity)?
    var released = false
  }
  private var entries: [String: Entry] = [:]

  func prepare(for destination: URL) throws -> [String: String] {
    let allocation = try FileManager.default.url(for: .itemReplacementDirectory,
      in: .userDomainMask, appropriateFor: destination, create: true)
      .resolvingSymlinksInPath().standardizedFileURL
    let child = allocation.appendingPathComponent("backup-operation")
    do {
      let fd = open(allocation.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard fd >= 0 else { throw Failure.unavailable(errno) }
      defer { close(fd) }
      let identity = try identify(fd)
      try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      let result = try registerEmpty(child)
      entries[result["token"]!]!.allocation = (allocation, identity)
      return result
    } catch {
      // Never recursive, including a failed allocation/registration.
      _ = rmdir(child.path)
      _ = rmdir(allocation.path)
      throw error
    }
  }

  // Internal seam also used by the standalone native lifecycle checks.
  func registerEmpty(_ directory: URL) throws -> [String: String] {
    guard directory.path == directory.resolvingSymlinksInPath().standardizedFileURL.path else {
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
    entries[token] = Entry(directory: directory, identity: identity)
    return ["directory": directory.path, "token": token]
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
    guard directory.path == directory.resolvingSymlinksInPath().standardizedFileURL.path,
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
      mode: value.st_mode)
  }
}
