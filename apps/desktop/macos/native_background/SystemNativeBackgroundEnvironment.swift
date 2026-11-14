import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import Security

/// Authenticated helper only. Eligibility comes from the live AX interface;
/// application identity is observed and pinned, never looked up in a list.
final class SystemMacNativeBackgroundEnvironment: MacNativeBackgroundEnvironment {
  private final class WindowIdentity {
    let window: AXUIElement
    let id = UUID().uuidString
    init(_ window: AXUIElement) { self.window = window }
  }
  private final class WeakWindowIdentity {
    weak var value: WindowIdentity?
    init(_ value: WindowIdentity) { self.value = value }
  }
  private struct NativeTree { let nodes: [AXUIElement]; let excludedWeb: Bool }
  private final class Reference {
    let process: MacFocusProcessWitness
    let executable: NativeExecutableWitness
    let signature: NativeSignatureWitness
    let app: AXUIElement
    let windowIdentity: WindowIdentity
    var window: AXUIElement { windowIdentity.window }
    let field: AXUIElement
    let epoch: UInt64
    let windowLabel: String
    let fieldLabel: String
    init(_ process: MacFocusProcessWitness, _ executable: NativeExecutableWitness,
         _ signature: NativeSignatureWitness, _ app: AXUIElement, _ window: WindowIdentity,
         _ field: AXUIElement, _ epoch: UInt64, _ windowLabel: String, _ fieldLabel: String) {
      self.process = process; self.executable = executable; self.signature = signature
      self.app = app; self.windowIdentity = window; self.field = field; self.epoch = epoch
      self.windowLabel = windowLabel; self.fieldLabel = fieldLabel
    }
  }
  private var deadline: TimeInterval = 0
  private var epoch: UInt64 = 0
  private var observations: [NSObjectProtocol] = []
  private var windowIDs: [WeakWindowIdentity] = []
  private let permission: () -> Bool
  private let workspace = NSWorkspace.shared.notificationCenter

  init(permission: @escaping () -> Bool = { AXIsProcessTrusted() }) {
    self.permission = permission
    for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                 NSWorkspace.sessionDidResignActiveNotification] {
      observations.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.epoch &+= 1
      })
    }
  }
  deinit { for token in observations { workspace.removeObserver(token) } }
  func checkAvailability() throws { try begin() }

  /// appId is only a discovery selector. Resolve the actual running process and
  /// file locally; a selector supplies neither an executable nor authorization.
  func application(_ appID: String) throws -> MacFocusApplication {
    try begin()
    let running = NSWorkspace.shared.runningApplications.filter {
      !$0.isTerminated && $0.processIdentifier != getpid() && $0.bundleIdentifier == appID
    }
    guard !running.isEmpty else { throw MacNativeBackgroundFailure.targetUnavailable }
    guard running.count == 1, let process = running.first else { throw MacNativeBackgroundFailure.ambiguousTarget }
    let witness = try processWitness(process.processIdentifier)
    guard process.executableURL?.resolvingSymlinksInPath().standardizedFileURL.path == witness.path else {
      throw MacNativeBackgroundFailure.targetChanged
    }
    let file = try NativeExecutableWitness(witness.path, deadline: deadline)
    _ = try NativeSignatureWitness(witness.pid)
    return try MacFocusApplication(executable: witness.path, sha256: file.sha256)
  }

  func discover(_ application: MacFocusApplication) throws -> [MacNativeBackgroundCandidate] {
    try begin()
    let running = NSWorkspace.shared.runningApplications.filter {
      !$0.isTerminated && $0.processIdentifier != getpid() &&
      $0.executableURL?.resolvingSymlinksInPath().standardizedFileURL.path == application.executable
    }
    guard !running.isEmpty else { throw MacNativeBackgroundFailure.targetUnavailable }
    guard running.count == 1, let process = running.first else { throw MacNativeBackgroundFailure.ambiguousTarget }
    let witness = try processWitness(process.processIdentifier)
    let signature = try NativeSignatureWitness(witness.pid)
    let executable = try NativeExecutableWitness(application.executable, deadline: deadline)
    guard executable.sha256 == application.sha256 else { throw MacNativeBackgroundFailure.targetChanged }
    let app = AXUIElementCreateApplication(witness.pid)
    var result: [MacNativeBackgroundCandidate] = []
    var descriptions = Set<String>()
    var unsupported = false
    windowIDs.removeAll { $0.value == nil }
    for window in try children(app, kAXWindowsAttribute) {
      guard try text(window, kAXRoleAttribute) == kAXWindowRole else { throw MacNativeBackgroundFailure.unsupportedTarget }
      let tree = try nativeTree(window)
      unsupported = unsupported || tree.excludedWeb
      for field in tree.nodes where try password(field) {
        let windowLabel: String, fieldLabel: String
        do {
          try writable(field)
          try ancestry(field, window: window, pid: witness.pid)
          windowLabel = try windowDescription(window)
          fieldLabel = try fieldDescription(field)
        } catch MacNativeBackgroundFailure.unsupportedTarget {
          unsupported = true; continue
        }
        guard descriptions.insert(windowLabel + "\u{0}" + fieldLabel).inserted else {
          throw MacNativeBackgroundFailure.ambiguousTarget
        }
        let identity: WindowIdentity
        if let existing = windowIDs.compactMap({ $0.value }).first(where: { CFEqual($0.window, window) }) { identity = existing }
        else {
          guard windowIDs.count < 256 else { throw MacNativeBackgroundFailure.busy }
          identity = WindowIdentity(window); windowIDs.append(WeakWindowIdentity(identity))
        }
        let reference = Reference(witness, executable, signature, app, identity, field, epoch, windowLabel, fieldLabel)
        try check(reference)
        let descriptor = MacNativeBackgroundDescriptor(candidateID: UUID(), windowIdentifier: identity.id,
          windowTitle: windowLabel, fieldIdentifier: try text(field, kAXIdentifierAttribute, optional: true), fieldLabel: fieldLabel)
        result.append(MacNativeBackgroundCandidate(descriptor: descriptor, reference: reference))
        guard result.count <= 64 else { throw MacNativeBackgroundFailure.ambiguousTarget }
      }
    }
    if result.isEmpty && unsupported { throw MacNativeBackgroundFailure.unsupportedTarget }
    return result
  }
  func sameTarget(_ a: MacNativeBackgroundCandidate, _ b: MacNativeBackgroundCandidate) -> Bool {
    guard let left = a.reference as? Reference, let right = b.reference as? Reference else { return false }
    return left.process == right.process && CFEqual(left.field, right.field)
  }
  func recheck(_ candidate: MacNativeBackgroundCandidate) throws {
    try begin()
    guard let ref = candidate.reference as? Reference else { throw MacNativeBackgroundFailure.targetUnavailable }
    try check(ref)
  }
  func write(_ secret: String, to candidate: MacNativeBackgroundCandidate,
             authorized: () -> Bool) -> MacNativeBackgroundWriteResult {
    do { try recheck(candidate) }
    catch { return .refused((error as? MacNativeBackgroundFailure) ?? .targetUnavailable) }
    guard authorized(), let ref = candidate.reference as? Reference else { return .refused(.unauthorized) }
    // Single whole-value mutation; no activation, focus, keyboard or clipboard.
    // The last recheck and external setter cannot form an atomic business lock.
    let status = AXUIElementSetAttributeValue(ref.field, kAXValueAttribute as CFString, secret as CFString)
    return status == .success ? .setterAccepted : .unknown
  }
  private func begin() throws {
    guard Thread.isMainThread else { throw MacNativeBackgroundFailure.wrongThread }
    guard permission() else { throw MacNativeBackgroundFailure.permissionRequired }
    deadline = ProcessInfo.processInfo.systemUptime + 2
    try session()
  }
  private func session() throws {
    guard let s = CGSessionCopyCurrentDictionary() as? [String: Any],
          (s[kCGSessionUserIDKey as String] as? NSNumber)?.uint32Value == geteuid(),
          s[kCGSessionOnConsoleKey as String] as? Bool == true,
          s[kCGSessionLoginDoneKey as String] as? Bool == true,
          s["CGSSessionScreenIsLocked"] as? Bool != true,
          NSApplication.shared.isProtectedDataAvailable else { throw MacNativeBackgroundFailure.sessionUnavailable }
  }
  private func check(_ ref: Reference) throws {
    try budget(); try session()
    guard permission() else { throw MacNativeBackgroundFailure.permissionRequired }
    guard ref.epoch == epoch, try processWitness(ref.process.pid) == ref.process,
          let running = NSRunningApplication(processIdentifier: ref.process.pid), !running.isTerminated,
          running.executableURL?.resolvingSymlinksInPath().standardizedFileURL.path == ref.process.path else {
      throw MacNativeBackgroundFailure.targetChanged
    }
    try ref.executable.recheck()
    guard try NativeSignatureWitness(ref.process.pid) == ref.signature else { throw MacNativeBackgroundFailure.targetChanged }
    for item in [ref.app, ref.window, ref.field] { try owner(item, pid: ref.process.pid) }
    guard try children(ref.app, kAXWindowsAttribute).filter({ CFEqual($0, ref.window) }).count == 1,
          try text(ref.window, kAXRoleAttribute) == kAXWindowRole,
          try nativeTree(ref.window).nodes.filter({ CFEqual($0, ref.field) }).count == 1,
          try password(ref.field), try windowDescription(ref.window) == ref.windowLabel,
          try fieldDescription(ref.field) == ref.fieldLabel else { throw MacNativeBackgroundFailure.targetChanged }
    try ancestry(ref.field, window: ref.window, pid: ref.process.pid)
    try writable(ref.field)
    // Recheck public descriptions of other live candidates too. Newly inserted
    // indistinguishable controls must not inherit a prepared target's label.
    var descriptions = Set<String>()
    for window in try children(ref.app, kAXWindowsAttribute) {
      for field in try nativeTree(window).nodes where try password(field) {
        do { try writable(field) } catch MacNativeBackgroundFailure.unsupportedTarget { continue }
        do {
          let label = try windowDescription(window) + "\u{0}" + fieldDescription(field)
          guard descriptions.insert(label).inserted else { throw MacNativeBackgroundFailure.ambiguousTarget }
        } catch MacNativeBackgroundFailure.unsupportedTarget { continue }
      }
    }
    try budget(); try session()
    guard ref.epoch == epoch else { throw MacNativeBackgroundFailure.sessionUnavailable }
  }
  private func password(_ field: AXUIElement) throws -> Bool {
    let role = try text(field, kAXRoleAttribute)
    let subrole = try text(field, kAXSubroleAttribute, optional: true)
    return role == kAXSecureTextFieldSubrole || role == kAXTextFieldRole && subrole == kAXSecureTextFieldSubrole
  }
  private func writable(_ field: AXUIElement) throws {
    guard try boolean(field, kAXEnabledAttribute) else { throw MacNativeBackgroundFailure.unsupportedTarget }
    var writable = DarwinBoolean(false)
    let status = AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &writable)
    if status == .apiDisabled { throw MacNativeBackgroundFailure.permissionRequired }
    if status == .attributeUnsupported { throw MacNativeBackgroundFailure.unsupportedTarget }
    guard status == .success else { throw MacNativeBackgroundFailure.targetUnavailable }
    guard writable.boolValue else { throw MacNativeBackgroundFailure.unsupportedTarget }
  }
  private func owner(_ item: AXUIElement, pid: pid_t) throws {
    var actual: pid_t = -1
    guard AXUIElementGetPid(item, &actual) == .success, actual == pid else { throw MacNativeBackgroundFailure.targetChanged }
  }
  private func web(_ node: AXUIElement) throws -> Bool {
    let role = try text(node, kAXRoleAttribute)
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(node, &names) == .success, let attributes = names as? [String] else {
      throw MacNativeBackgroundFailure.targetUnavailable
    }
    return ["AXWebArea", "AXWebView", "AXHTMLArea"].contains(role) ||
      attributes.contains("AXDOMIdentifier") || attributes.contains("AXDOMClassList") || attributes.contains("ChromeAXNodeId")
  }
  /// Skip a known web subtree only. A native sibling remains eligible.
  private func nativeTree(_ root: AXUIElement) throws -> NativeTree {
    var excludedWeb = false
    var visited = 0
    var result: [AXUIElement] = [], pending: [(AXUIElement, Int)] = [(root, 0)]
    while let (node, depth) = pending.popLast() {
      try budget()
      guard depth <= 24, visited < 2048, !result.contains(where: { CFEqual($0, node) }) else {
        throw MacNativeBackgroundFailure.unsupportedTarget
      }
      visited += 1
      if try web(node) { excludedWeb = true; continue }
      result.append(node)
      let descendants = try children(node, kAXChildrenAttribute, optional: true)
      guard pending.count + descendants.count + visited <= 2048 else { throw MacNativeBackgroundFailure.unsupportedTarget }
      for child in descendants { pending.append((child, depth + 1)) }
    }
    return NativeTree(nodes: result, excludedWeb: excludedWeb)
  }
  private func ancestry(_ field: AXUIElement, window: AXUIElement, pid: pid_t) throws {
    var current = field, seen: [AXUIElement] = []
    for _ in 0..<25 {
      try owner(current, pid: pid)
      guard !seen.contains(where: { CFEqual($0, current) }), try !web(current) else {
        throw MacNativeBackgroundFailure.unsupportedTarget
      }
      if CFEqual(current, window) { return }
      seen.append(current)
      guard let parent = try axElement(current, kAXParentAttribute) else { throw MacNativeBackgroundFailure.targetChanged }
      current = parent
    }
    throw MacNativeBackgroundFailure.unsupportedTarget
  }
  private func windowDescription(_ window: AXUIElement) throws -> String {
    let title = try text(window, kAXTitleAttribute, optional: true)
    let description = try text(window, kAXDescriptionAttribute, optional: true)
    return try MacNativeBackgroundCapability.label(title.isEmpty ? description : title,
      identifier: text(window, kAXIdentifierAttribute, optional: true))
  }
  private func fieldDescription(_ field: AXUIElement) throws -> String {
    var labels: [String] = []
    for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, "AXPlaceholderValue"] {
      let value = try text(field, name, optional: true)
      if !value.isEmpty && !labels.contains(value) { labels.append(value) }
    }
    if let label = try axElement(field, kAXTitleUIElementAttribute, optional: true),
       try text(label, kAXRoleAttribute) == kAXStaticTextRole {
      let value = try text(label, kAXValueAttribute, optional: true)
      if !value.isEmpty && !labels.contains(value) { labels.append(value) }
    }
    return try MacNativeBackgroundCapability.label(labels.joined(separator: " / "),
      identifier: text(field, kAXIdentifierAttribute, optional: true))
  }
  private func budget() throws {
    guard ProcessInfo.processInfo.systemUptime < deadline else { throw MacNativeBackgroundFailure.targetUnavailable }
  }
  private func attribute(_ e: AXUIElement, _ name: String, optional: Bool = false) throws -> CFTypeRef? {
    try budget()
    guard AXUIElementSetMessagingTimeout(e, 0.15) == .success else { throw MacNativeBackgroundFailure.targetUnavailable }
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(e, name as CFString, &value)
    if status == .apiDisabled { throw MacNativeBackgroundFailure.permissionRequired }
    if optional && (status == .attributeUnsupported || status == .noValue) { return nil }
    guard status == .success, let value else { throw MacNativeBackgroundFailure.targetUnavailable }
    return value
  }
  private func children(_ e: AXUIElement, _ name: String, optional: Bool = false) throws -> [AXUIElement] {
    guard let v = try attribute(e, name, optional: optional) else { return [] }
    guard let result = v as? [AXUIElement] else { throw MacNativeBackgroundFailure.unsupportedTarget }
    return result
  }
  private func text(_ e: AXUIElement, _ name: String, optional: Bool = false) throws -> String {
    guard let value = try attribute(e, name, optional: optional) else { return "" }
    guard let result = value as? String, result.utf8.count <= 4096 else { throw MacNativeBackgroundFailure.unsupportedTarget }
    return result
  }
  private func boolean(_ e: AXUIElement, _ name: String) throws -> Bool {
    guard let v = try attribute(e, name), CFGetTypeID(v) == CFBooleanGetTypeID(), let b = v as? Bool else {
      throw MacNativeBackgroundFailure.unsupportedTarget
    }
    return b
  }
  private func axElement(_ e: AXUIElement, _ name: String, optional: Bool = false) throws -> AXUIElement? {
    guard let v = try attribute(e, name, optional: optional) else { return nil }
    guard CFGetTypeID(v) == AXUIElementGetTypeID() else { throw MacNativeBackgroundFailure.unsupportedTarget }
    return unsafeBitCast(v, to: AXUIElement.self)
  }
  private func processWitness(_ pid: pid_t) throws -> MacFocusProcessWitness {
    do { return try MacFocusProcessWitness(pid) }
    catch { throw MacNativeBackgroundFailure.targetChanged }
  }
}

/// Pin the actual running code when signed. An explicitly unsigned process is
/// still bound by its process generation, executable descriptor and AX objects.
private struct NativeSignatureWitness: Equatable {
  let cdhash: Data?
  init(_ pid: pid_t) throws {
    var code: SecCode?
    let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
    let status = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
    if status == errSecCSUnsigned { cdhash = nil; return }
    guard status == errSecSuccess, let code else { throw MacNativeBackgroundFailure.targetChanged }
    let valid = SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
    if valid == errSecCSUnsigned { cdhash = nil; return }
    guard valid == errSecSuccess else { throw MacNativeBackgroundFailure.targetChanged }
    var staticCode: SecStaticCode?, info: CFDictionary?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
          let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty else {
      throw MacNativeBackgroundFailure.targetChanged
    }
    cdhash = hash
  }
}

private final class NativeExecutableWitness {
  let sha256: String
  private let fd: Int32
  private let path: String
  private let metadata: stat
  init(_ path: String, deadline: TimeInterval) throws {
    let file = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard file >= 0 else { throw MacNativeBackgroundFailure.targetChanged }
    var initial = stat()
    guard fstat(file, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
          initial.st_uid == geteuid() || initial.st_uid == 0,
          initial.st_mode & 0o022 == 0, initial.st_size > 0, initial.st_size <= 512 * 1024 * 1024 else {
      Darwin.close(file); throw MacNativeBackgroundFailure.targetChanged
    }
    var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 65536)
    do {
      var total: Int64 = 0
      while true {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw MacNativeBackgroundFailure.targetUnavailable }
        let count = Darwin.read(file, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        guard count >= 0 else { throw MacNativeBackgroundFailure.targetChanged }
        if count == 0 { break }
        total += Int64(count)
        guard total <= initial.st_size else { throw MacNativeBackgroundFailure.targetChanged }
        buffer.withUnsafeBytes { hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])) }
      }
      var after = stat(), located = stat()
      guard total == initial.st_size, fstat(file, &after) == 0, lstat(path, &located) == 0,
            Self.same(initial, after), Self.same(initial, located) else { throw MacNativeBackgroundFailure.targetChanged }
    } catch { Darwin.close(file); throw error }
    fd = file; self.path = path; metadata = initial
    sha256 = hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
  deinit { Darwin.close(fd) }
  func recheck() throws {
    var current = stat(), located = stat()
    guard fstat(fd, &current) == 0, lstat(path, &located) == 0,
          Self.same(metadata, current), Self.same(metadata, located) else { throw MacNativeBackgroundFailure.targetChanged }
  }
  private static func same(_ a: stat, _ b: stat) -> Bool {
    a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_size == b.st_size &&
    a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
    a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
  }
}
