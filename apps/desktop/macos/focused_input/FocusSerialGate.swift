import Foundation
import Darwin

/// One non-queued input lease per login user, including separate helper
/// processes. The file contains no credential, target, PID or operation data.
final class MacFocusFileGate: MacFocusSerialGate {
  private let base: URL
  private let lock = NSLock()
  private var held: Int32 = -1
  private var directory: Int32 = -1

  init(base: URL? = nil) {
    self.base = base ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
  }

  deinit { release() }

  func acquire() throws {
    lock.lock()
    defer { lock.unlock() }
    guard held < 0 else { throw MacFocusFailure("busy") }
    let root = open(base.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard root >= 0 else { throw MacFocusFailure("access_denied") }
    defer { Darwin.close(root) }
    var rootInfo = stat()
    guard fstat(root, &rootInfo) == 0, rootInfo.st_uid == geteuid(),
          rootInfo.st_mode & S_IFMT == S_IFDIR, rootInfo.st_mode & 0o022 == 0 else {
      throw MacFocusFailure("access_denied")
    }
    let name = "org.shijijs.agent-info-manage.focused-fill"
    let made = mkdirat(root, name, 0o700)
    guard made == 0 || errno == EEXIST else { throw MacFocusFailure("access_denied") }
    let folder = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard folder >= 0 else { throw MacFocusFailure("access_denied") }
    var info = stat()
    guard fstat(folder, &info) == 0, info.st_uid == geteuid(),
          info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o700 else {
      Darwin.close(folder)
      throw MacFocusFailure("access_denied")
    }
    let file = openat(folder, "input.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard file >= 0 else { Darwin.close(folder); throw MacFocusFailure("access_denied") }
    guard fstat(file, &info) == 0, info.st_uid == geteuid(), info.st_nlink == 1,
          info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600 else {
      Darwin.close(file)
      Darwin.close(folder)
      throw MacFocusFailure("access_denied")
    }
    guard flock(file, LOCK_EX | LOCK_NB) == 0 else {
      Darwin.close(file)
      Darwin.close(folder)
      throw MacFocusFailure("busy")
    }
    // Bind the lock to the currently named file/directory after acquiring it;
    // do not silently follow an existing alias or replace someone else's lock.
    var located = stat()
    var folderInfo = stat()
    var folderLocated = stat()
    guard fstatat(folder, "input.lock", &located, AT_SYMLINK_NOFOLLOW) == 0,
          info.st_dev == located.st_dev, info.st_ino == located.st_ino,
          fstat(folder, &folderInfo) == 0,
          fstatat(root, name, &folderLocated, AT_SYMLINK_NOFOLLOW) == 0,
          folderInfo.st_dev == folderLocated.st_dev, folderInfo.st_ino == folderLocated.st_ino else {
      _ = flock(file, LOCK_UN)
      Darwin.close(file)
      Darwin.close(folder)
      throw MacFocusFailure("access_denied")
    }
    held = file
    directory = folder
  }

  func release() {
    lock.lock()
    defer { lock.unlock() }
    if held >= 0 { _ = flock(held, LOCK_UN); Darwin.close(held); held = -1 }
    if directory >= 0 { Darwin.close(directory); directory = -1 }
  }
}
