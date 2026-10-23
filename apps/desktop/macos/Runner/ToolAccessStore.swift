import Foundation
import Darwin

struct ToolAccessFailure: Error {
  let code: String
}

enum ToolDirectoryPermission: String, Codable {
  case readOnly, readWrite
}

protocol ToolDirectoryScopes {
  func bookmark(_ url: URL, permission: ToolDirectoryPermission) throws -> Data
  func resolve(_ data: Data) throws -> (URL, Bool)
  func start(_ url: URL) -> Bool
  func stop(_ url: URL)
}

struct SystemToolDirectoryScopes: ToolDirectoryScopes {
  func bookmark(_ url: URL, permission: ToolDirectoryPermission) throws -> Data {
    var options: URL.BookmarkCreationOptions = [.withSecurityScope]
    if permission == .readOnly { options.insert(.securityScopeAllowOnlyReadAccess) }
    return try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
  }
  func resolve(_ data: Data) throws -> (URL, Bool) {
    var stale = false
    let url = try URL(resolvingBookmarkData: data,
                      options: [.withSecurityScope, .withoutUI, .withoutMounting],
                      relativeTo: nil, bookmarkDataIsStale: &stale)
    return (url, stale)
  }
  func start(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
  func stop(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

/// Owner-only OS access, separate from credential grants and portable backups.
/// All calls are serialized on the native UI thread. Bookmark bytes never leave
/// this object through a Flutter or Agent response.
final class ToolAccessStore {
  private struct Entry: Codable {
    let id: String
    let path: String
    let bookmark: Data
    let permission: ToolDirectoryPermission?
    var savedPermission: ToolDirectoryPermission { permission ?? .readOnly }
  }
  private struct Archive: Codable {
    let version: Int
    let entries: [Entry]
  }
  private let file: URL
  private let scopes: ToolDirectoryScopes
  private var entries: [Entry] = []
  private var active: [String: URL] = [:]
  private(set) var loadFailed = false

  init(file: URL, scopes: ToolDirectoryScopes = SystemToolDirectoryScopes()) {
    self.file = file
    self.scopes = scopes
    do {
      if FileManager.default.fileExists(atPath: file.path) {
        guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
          throw ToolAccessFailure(code: "tool_access_storage_failed")
        }
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        let data = try input.read(upToCount: 1024 * 1024 + 1) ?? Data()
        guard data.count <= 1024 * 1024 else {
          throw ToolAccessFailure(code: "tool_access_storage_failed")
        }
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        guard (archive.version == 1 || archive.version == 2), archive.entries.count <= 16,
              Set(archive.entries.map { $0.id }).count == archive.entries.count,
              archive.entries.allSatisfy({
                UUID(uuidString: $0.id) != nil && $0.path.hasPrefix("/") &&
                  $0.path.utf8.count <= 16384 && !$0.bookmark.isEmpty &&
                  $0.bookmark.count <= 65536 &&
                  (archive.version == 1 ? $0.permission == nil : $0.permission != nil)
              }) else { throw ToolAccessFailure(code: "tool_access_storage_failed") }
        entries = archive.entries
        for entry in entries {
          if let url = try? activate(entry.bookmark) { active[entry.id] = url }
        }
      }
    } catch {
      loadFailed = true
    }
  }

  deinit {
    for url in active.values { scopes.stop(url) }
  }

  func snapshot() -> [String: Any] {
    for (id, url) in active {
      // URL resource values are cached. Recheck the filesystem so a removed or
      // disconnected directory is not reported as available until restart.
      var probe = url
      probe.removeAllCachedResourceValues()
      if (try? probe.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
        scopes.stop(url)
        active.removeValue(forKey: id)
      }
    }
    // A volume may reconnect after launch or after the previous status read.
    // Retry only the already saved security-scoped bookmark: never fall back
    // to the stored path, recreate a stale bookmark, mount a volume, or prompt.
    // An active token must not be started twice by repeated refreshes.
    for entry in entries where active[entry.id] == nil {
      if let url = try? activate(entry.bookmark) { active[entry.id] = url }
    }
    return [
      "storageUnavailable": loadFailed,
      "directories": entries.map { entry -> [String: Any] in
        let path = active[entry.id]?.path ?? entry.path
        return [
          "id": entry.id, "path": path,
          "name": URL(fileURLWithPath: path).lastPathComponent,
          "available": active[entry.id] != nil,
          "permission": entry.savedPermission.rawValue
        ]
      }
    ]
  }

  /// Only call with an owner-selected NSOpenPanel URL. Paths from Agent input
  /// or Flutter text fields cannot create filesystem access.
  func rememberSelection(_ selected: URL, replacing id: String? = nil,
                         permission: ToolDirectoryPermission = .readOnly) throws {
    guard !loadFailed else { throw ToolAccessFailure(code: "tool_access_storage_failed") }
    if let id = id, !entries.contains(where: { $0.id == id }) {
      throw ToolAccessFailure(code: "tool_access_unknown")
    }
    guard selected.isFileURL,
          try selected.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
      throw ToolAccessFailure(code: "tool_access_not_directory")
    }
    let bookmark = try scopes.bookmark(selected, permission: permission)
    guard !bookmark.isEmpty, bookmark.count <= 65536 else {
      throw ToolAccessFailure(code: "tool_access_unavailable")
    }
    let resolved = try activate(bookmark)
    var installed = false
    defer { if !installed { scopes.stop(resolved) } }
    let duplicate = entries.first { active[$0.id]?.path == resolved.path || $0.path == resolved.path }
    let targetID = id ?? duplicate?.id ?? UUID().uuidString
    // Replacing an entry with another saved directory must not duplicate it.
    if let duplicate = duplicate, duplicate.id != targetID {
      throw ToolAccessFailure(code: "tool_access_duplicate")
    }
    let entry = Entry(id: targetID, path: resolved.path, bookmark: bookmark, permission: permission)
    var next = entries.filter { $0.id != targetID }
    guard next.count < 16 else { throw ToolAccessFailure(code: "tool_access_limit") }
    next.append(entry)
    try persist(next)
    if let old = active.removeValue(forKey: targetID) { scopes.stop(old) }
    active[targetID] = resolved
    entries = next
    installed = true
  }

  func forget(_ id: String) throws {
    guard !loadFailed else { throw ToolAccessFailure(code: "tool_access_storage_failed") }
    guard entries.contains(where: { $0.id == id }) else {
      throw ToolAccessFailure(code: "tool_access_unknown")
    }
    let next = entries.filter { $0.id != id }
    try persist(next)
    entries = next
    if let url = active.removeValue(forKey: id) { scopes.stop(url) }
  }

  private func activate(_ bookmark: Data) throws -> URL {
    let (url, stale) = try scopes.resolve(bookmark)
    guard !stale, url.isFileURL, scopes.start(url) else {
      throw ToolAccessFailure(code: "tool_access_unavailable")
    }
    do {
      guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
        throw ToolAccessFailure(code: "tool_access_not_directory")
      }
      return url
    } catch {
      scopes.stop(url)
      throw error
    }
  }

  private func persist(_ next: [Entry]) throws {
    let manager = FileManager.default
    let directory = file.deletingLastPathComponent()
    let temporary = directory.appendingPathComponent(".tool-access-\(UUID().uuidString)")
    do {
      try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
      guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
        throw ToolAccessFailure(code: "tool_access_storage_failed")
      }
      // v1 tokens were always read-only. Migrate their metadata only when an
      // owner changes the list; never recreate or broaden those bookmarks.
      // v2 makes old readers fail closed instead of mislabelling RW tokens.
      let normalized = next.map {
        Entry(id: $0.id, path: $0.path, bookmark: $0.bookmark, permission: $0.savedPermission)
      }
      let data = try JSONEncoder().encode(Archive(version: 2, entries: normalized))
      guard data.count <= 1024 * 1024 else {
        throw ToolAccessFailure(code: "tool_access_storage_failed")
      }
      let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
      guard descriptor >= 0 else { throw ToolAccessFailure(code: "tool_access_storage_failed") }
      defer { try? manager.removeItem(at: temporary) }
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      defer { try? handle.close() }
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
      guard rename(temporary.path, file.path) == 0 else {
        throw ToolAccessFailure(code: "tool_access_storage_failed")
      }
    } catch {
      throw ToolAccessFailure(code: "tool_access_storage_failed")
    }
  }
}
