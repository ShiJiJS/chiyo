import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import Security

/// Link only into the authenticated, unsandboxed helper, never Runner. Default
/// compatibility is empty; a role resembling a password box does not enable it.
final class SystemMacNativeBackgroundEnvironment: MacNativeBackgroundEnvironment {
  private final class Reference {
    let process: MacFocusProcessWitness
    let executable: NativeExecutableWitness
    let profile: MacNativeBackgroundProfile
    let app: AXUIElement
    let window: AXUIElement
    let field: AXUIElement
    let epoch: UInt64
    let context: [String: String]
    init(_ process: MacFocusProcessWitness, _ executable: NativeExecutableWitness,
         _ profile: MacNativeBackgroundProfile, _ app: AXUIElement,
         _ window: AXUIElement, _ field: AXUIElement, _ epoch: UInt64, _ context: [String: String]) {
      self.process = process; self.executable = executable; self.profile = profile
      self.app = app; self.window = window; self.field = field; self.epoch = epoch
      self.context = context
    }
  }
  private let profiles: [MacNativeBackgroundProfile]
  private var deadline: TimeInterval = 0
  private var epoch: UInt64 = 0
  private var observations: [NSObjectProtocol] = []
  private let workspace = NSWorkspace.shared.notificationCenter

  init(profiles: [MacNativeBackgroundProfile] = []) {
    self.profiles = profiles
    for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                 NSWorkspace.sessionDidResignActiveNotification] {
      observations.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.epoch &+= 1
      })
    }
  }
  deinit { for token in observations { workspace.removeObserver(token) } }
  func checkAvailability() throws { try begin() }

  func discover(_ application: MacFocusApplication) throws -> [MacNativeBackgroundCandidate] {
    try begin()
    let matching = profiles.filter { $0.application == application }
    guard matching.count == 1, let profile = matching.first,
          !profile.bundleIdentifier.isEmpty,
          profile.codeRequirement.range(of: "^cdhash H\"[0-9a-f]{40}\"$", options: .regularExpression) != nil,
          !profile.windowIdentifiers.isEmpty,
          !profile.fieldIdentifiers.isEmpty,
          !profile.windowIdentifiers.contains(""), !profile.fieldIdentifiers.contains("") else {
      throw MacNativeBackgroundFailure.unsupportedApplication
    }
    try platform(profile)
    let running = NSWorkspace.shared.runningApplications.filter {
      !$0.isTerminated && $0.processIdentifier != getpid() &&
      $0.bundleIdentifier == profile.bundleIdentifier &&
      $0.executableURL?.resolvingSymlinksInPath().standardizedFileURL.path == application.executable
    }
    if running.isEmpty { return [] }
    guard running.count == 1, let process = running.first else {
      throw MacNativeBackgroundFailure.ambiguousTarget
    }
    let witness = try processWitness(process.processIdentifier)
    try signedProcess(witness.pid, requirement: profile.codeRequirement)
    let executable = try NativeExecutableWitness(application.executable, deadline: deadline)
    guard executable.sha256 == application.sha256 else { throw MacNativeBackgroundFailure.targetChanged }
    let app = AXUIElementCreateApplication(witness.pid)
    let windows = try children(app, kAXWindowsAttribute)
    var result: [MacNativeBackgroundCandidate] = []
    var identities = Set<String>()
    for window in windows {
      let identifier = try text(window, kAXIdentifierAttribute)
      guard profile.windowIdentifiers.contains(identifier) else { continue }
      let nodes = try nativeTree(window)
      let observedContext = try context(profile, nodes)
      for field in nodes where try text(field, kAXRoleAttribute) == kAXTextFieldRole && text(field, kAXSubroleAttribute, optional: true) == kAXSecureTextFieldSubrole {
        let fieldID = try text(field, kAXIdentifierAttribute)
        guard profile.fieldIdentifiers.contains(fieldID) else { continue }
        guard identifier.utf16.count <= 128, fieldID.utf16.count <= 128,
              !(identifier + fieldID).unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
          throw MacNativeBackgroundFailure.ambiguousTarget
        }
        // Known unavailable fields are not initial discovery candidates. Unknown
        // metadata remains a failure. Captured fields are always rechecked.
        if try !boolean(field, kAXEnabledAttribute) { continue }
        var writable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(field, kAXValueAttribute as CFString, &writable) == .success else {
          throw MacNativeBackgroundFailure.targetUnavailable
        }
        if !writable.boolValue { continue }
        guard identities.insert(identifier + "\u{0}" + fieldID).inserted else {
          throw MacNativeBackgroundFailure.ambiguousTarget
        }
        let reference = Reference(witness, executable, profile, app, window, field, epoch, observedContext)
        try check(reference)
        let descriptor = MacNativeBackgroundDescriptor(candidateID: UUID(), windowIdentifier: identifier,
          windowTitle: try text(window, kAXTitleAttribute, optional: true), fieldIdentifier: fieldID,
          fieldLabel: (try profile.fieldLabels[fieldID] ?? text(field, kAXDescriptionAttribute, optional: true)) +
            (observedContext.isEmpty ? "" : " — " + observedContext.values.sorted().joined(separator: " / ")))
        result.append(MacNativeBackgroundCandidate(descriptor: descriptor, reference: reference))
        guard result.count <= 64 else { throw MacNativeBackgroundFailure.ambiguousTarget }
      }
    }
    return result
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
    // The only mutation in this adapter. This is deliberately NOT an atomic
    // window-liveness/authorization lock: close/revocation can race this call.
    let status = AXUIElementSetAttributeValue(ref.field, kAXValueAttribute as CFString, secret as CFString)
    return status == .success ? .setterAccepted : .unknown
  }

  private func begin() throws {
    guard Thread.isMainThread else { throw MacNativeBackgroundFailure.wrongThread }
    guard AXIsProcessTrusted() else { throw MacNativeBackgroundFailure.permissionRequired }
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
    try platform(ref.profile)
    guard ref.epoch == epoch, try processWitness(ref.process.pid) == ref.process,
          let running = NSRunningApplication(processIdentifier: ref.process.pid), !running.isTerminated,
          running.bundleIdentifier == ref.profile.bundleIdentifier,
          running.executableURL?.resolvingSymlinksInPath().standardizedFileURL.path == ref.process.path else {
      throw MacNativeBackgroundFailure.targetChanged
    }
    try ref.executable.recheck()
    try signedProcess(ref.process.pid, requirement: ref.profile.codeRequirement)
    for item in [ref.app, ref.window, ref.field] {
      var pid: pid_t = -1
      guard AXUIElementGetPid(item, &pid) == .success, pid == ref.process.pid else {
        throw MacNativeBackgroundFailure.targetChanged
      }
    }
    let windows = try children(ref.app, kAXWindowsAttribute)
    let windowID = try text(ref.window, kAXIdentifierAttribute)
    guard windows.filter({ CFEqual($0, ref.window) }).count == 1,
          ref.profile.windowIdentifiers.contains(windowID),
          try text(ref.window, kAXRoleAttribute) == kAXWindowRole,
          try windows.filter({ try text($0, kAXIdentifierAttribute) == windowID }).count == 1 else {
      throw MacNativeBackgroundFailure.targetChanged
    }
    let nodes = try nativeTree(ref.window)
    guard try context(ref.profile, nodes) == ref.context else { throw MacNativeBackgroundFailure.targetChanged }
    let id = try text(ref.field, kAXIdentifierAttribute)
    let matching = try nodes.filter { try text($0, kAXIdentifierAttribute, optional: true) == id }
    guard matching.count == 1, CFEqual(matching[0], ref.field),
          ref.profile.fieldIdentifiers.contains(id),
          try text(ref.field, kAXRoleAttribute) == kAXTextFieldRole,
          try text(ref.field, kAXSubroleAttribute) == kAXSecureTextFieldSubrole,
          try boolean(ref.field, kAXEnabledAttribute),
          let owner = try axElement(ref.field, kAXWindowAttribute), CFEqual(owner, ref.window) else {
      throw MacNativeBackgroundFailure.targetChanged
    }
    var settable = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(ref.field, kAXValueAttribute as CFString, &settable) == .success,
          settable.boolValue else { throw MacNativeBackgroundFailure.unsupportedTarget }
    try budget(); try session()
    guard ref.epoch == epoch else { throw MacNativeBackgroundFailure.sessionUnavailable }
  }

  /// Whole-window rejection is intentionally conservative for mixed windows.
  /// Public AX cannot establish the native implementation class; the exact
  /// tested profile supplies positive evidence, this scan supplies exclusions.
  private func nativeTree(_ root: AXUIElement) throws -> [AXUIElement] {
    var result: [AXUIElement] = [], pending: [(AXUIElement, Int)] = [(root, 0)]
    while let (node, depth) = pending.popLast() {
      try budget()
      guard depth <= 24, result.count < 2048, !result.contains(where: { CFEqual($0, node) }) else {
        throw MacNativeBackgroundFailure.unsupportedTarget
      }
      let role = try text(node, kAXRoleAttribute)
      var names: CFArray?
      guard AXUIElementCopyAttributeNames(node, &names) == .success,
            let attributes = names as? [String],
            role != "AXWebArea", !attributes.contains("AXDOMIdentifier"),
            !attributes.contains("ChromeAXNodeId") else { throw MacNativeBackgroundFailure.unsupportedTarget }
      result.append(node)
      for child in try children(node, kAXChildrenAttribute, optional: true) { pending.append((child, depth + 1)) }
    }
    return result
  }
  private func budget() throws {
    guard ProcessInfo.processInfo.systemUptime < deadline else { throw MacNativeBackgroundFailure.targetUnavailable }
  }
  private func attribute(_ e: AXUIElement, _ name: String, optional: Bool = false) throws -> CFTypeRef? {
    try budget()
    guard AXUIElementSetMessagingTimeout(e, 0.15) == .success else { throw MacNativeBackgroundFailure.targetUnavailable }
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(e, name as CFString, &value)
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
    guard let result = value as? String, result.utf8.count <= 1024 else { throw MacNativeBackgroundFailure.unsupportedTarget }
    return result
  }
  private func boolean(_ e: AXUIElement, _ name: String) throws -> Bool {
    guard let v = try attribute(e, name), CFGetTypeID(v) == CFBooleanGetTypeID(), let b = v as? Bool else {
      throw MacNativeBackgroundFailure.unsupportedTarget
    }
    return b
  }
  private func axElement(_ e: AXUIElement, _ name: String) throws -> AXUIElement? {
    guard let v = try attribute(e, name), CFGetTypeID(v) == AXUIElementGetTypeID() else {
      throw MacNativeBackgroundFailure.unsupportedTarget
    }
    return unsafeBitCast(v, to: AXUIElement.self)
  }
  private func processWitness(_ pid: pid_t) throws -> MacFocusProcessWitness {
    do { return try MacFocusProcessWitness(pid) }
    catch { throw MacNativeBackgroundFailure.targetChanged }
  }
  private func context(_ profile: MacNativeBackgroundProfile, _ nodes: [AXUIElement]) throws -> [String: String] {
    if let expected = profile.requiredSecureFieldIdentifiers {
      let secure = try nodes.filter { try text($0, kAXRoleAttribute) == kAXTextFieldRole && text($0, kAXSubroleAttribute, optional: true) == kAXSecureTextFieldSubrole }
      let ids = try secure.map { try text($0, kAXIdentifierAttribute) }
      guard ids.count == expected.count, Set(ids) == expected else { throw MacNativeBackgroundFailure.unsupportedTarget }
    }
    var result: [String: String] = [:]
    for id in profile.contextIdentifiers {
      let matching = try nodes.filter { try text($0, kAXIdentifierAttribute, optional: true) == id }
      guard matching.count == 1, try text(matching[0], kAXRoleAttribute) == kAXStaticTextRole else {
        throw MacNativeBackgroundFailure.unsupportedTarget
      }
      // Explicitly typed STATIC label metadata only, never a password field.
      let value = try text(matching[0], kAXValueAttribute)
      guard !value.isEmpty else { throw MacNativeBackgroundFailure.unsupportedTarget }
      if let pattern = profile.contextPatterns[id], value.range(of: pattern, options: .regularExpression) == nil {
        throw MacNativeBackgroundFailure.unsupportedTarget
      }
      result[id] = value
    }
    return result
  }
  private func signedProcess(_ pid: pid_t, requirement: String) throws {
    var code: SecCode?
    var expected: SecRequirement?
    let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
          SecRequirementCreateWithString(requirement as CFString, [], &expected) == errSecSuccess, let expected,
          SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), expected) == errSecSuccess else {
      throw MacNativeBackgroundFailure.targetChanged
    }
  }
  private func platform(_ profile: MacNativeBackgroundProfile) throws {
    guard let expected = profile.operatingSystemBuild else { return }
    var length = 0
    guard sysctlbyname("kern.osversion", nil, &length, nil, 0) == 0, length > 0, length < 128 else {
      throw MacNativeBackgroundFailure.unsupportedApplication
    }
    var bytes = [CChar](repeating: 0, count: length)
    guard sysctlbyname("kern.osversion", &bytes, &length, nil, 0) == 0,
          String(cString: bytes) == expected else { throw MacNativeBackgroundFailure.unsupportedApplication }
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
