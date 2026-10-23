import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
import Darwin

/// These public facts are necessary, but do not prove that a desktop is
/// unlocked. Only owner-built, independently validated session policy may admit
/// them. The current support matrix is empty; the default always refuses.
struct MacFocusSessionFacts {
  let user: uid_t
  let onConsole: Bool
  let loginComplete: Bool
  let protectedDataAvailable: Bool
  let operatingSystem: OperatingSystemVersion
}

/// Candidate XPC-side Adapter. This source is deliberately absent from Runner's
/// build target. Do not embed it in the sandboxed Runner/worker, or enable the
/// capability before helper identity, permission attribution and session policy
/// have real-machine evidence.
final class SystemMacFocusEnvironment: MacFocusEnvironment {
  private final class Reference {
    let process: MacFocusProcessWitness
    let executable: ExecutableWitness
    let app: AXUIElement
    let window: AXUIElement
    let field: AXUIElement
    let epoch: UInt64
    init(process: MacFocusProcessWitness, executable: ExecutableWitness,
         app: AXUIElement, window: AXUIElement, field: AXUIElement, epoch: UInt64) {
      self.process = process
      self.executable = executable
      self.app = app
      self.window = window
      self.field = field
      self.epoch = epoch
    }
  }

  private let supportedSession: (MacFocusSessionFacts) -> Bool
  private let connected: () -> Bool
  private var epoch: UInt64 = 0
  private var observations: [(NotificationCenter, NSObjectProtocol)] = []
  private let clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  private var deadline: TimeInterval = 0

  init(supportedSession: @escaping (MacFocusSessionFacts) -> Bool = { _ in false },
       connected: @escaping () -> Bool = { false }) {
    self.supportedSession = supportedSession
    self.connected = connected
    // Notifications only invalidate an existing capture. They never establish
    // an unlocked state, and an old capture stays invalid after waking/unlocking.
    let workspace = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                 NSWorkspace.sessionDidResignActiveNotification] {
      observe(workspace, name)
    }
    observe(.default, .NSApplicationProtectedDataWillBecomeUnavailable)
  }

  deinit { for (center, token) in observations { center.removeObserver(token) } }

  private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
    let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
      self?.epoch &+= 1
    }
    observations.append((center, token))
  }

  func capture() throws -> MacFocusTarget {
    try begin()
    let initialEpoch = epoch
    let running = try foreground()
    let process = try MacFocusProcessWitness(running.processIdentifier)
    guard let url = running.executableURL else { throw MacFocusFailure("application_changed") }
    let path = url.resolvingSymlinksInPath().standardizedFileURL.path
    guard path == process.path else { throw MacFocusFailure("application_changed") }
    let executable = try ExecutableWitness(path, deadline: deadline)
    let application = try MacFocusApplication(executable: path, sha256: executable.sha256)
    let app = AXUIElementCreateApplication(process.pid)
    let system = AXUIElementCreateSystemWide()
    try timeout(app)
    try timeout(system)
    let focusedApp = try element(system, kAXFocusedApplicationAttribute)
    guard CFEqual(app, focusedApp) else { throw MacFocusFailure("focus_changed") }
    let field = try element(app, kAXFocusedUIElementAttribute)
    let window = try element(app, kAXFocusedWindowAttribute)
    let reference = Reference(process: process, executable: executable,
      app: app, window: window, field: field, epoch: initialEpoch)
    let target = MacFocusTarget(application: application, reference: reference)
    try check(reference)
    return target
  }

  func recheck(_ target: MacFocusTarget) throws {
    try begin()
    guard let reference = target.reference as? Reference,
          target.application.executable == reference.process.path,
          target.application.sha256 == reference.executable.sha256 else {
      throw MacFocusFailure("application_changed")
    }
    try check(reference)
  }

  func post(_ units: [UInt16], to target: MacFocusTarget) throws -> MacFocusPosting {
    // Construct both bounded events before posting anything. An allocation
    // failure at this point is a definite refusal. Controller validates UTF-16.
    guard !units.isEmpty, units.count <= 16,
          let reference = target.reference as? Reference,
          let source = CGEventSource(stateID: .privateState),
          let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
      return .refused("input_rejected")
    }
    down.flags = []
    up.flags = []
    units.withUnsafeBufferPointer { buffer in
      down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
      up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
    }
    // Last full observation immediately precedes the two directed posts. This
    // is not an atomic focus lock, and the API has no delivery/acceptance count.
    do { try recheck(target) }
    catch { return .refused((error as? MacFocusFailure)?.code ?? "target_unavailable") }
    guard connected() else { return .refused("session_unavailable") }
    down.postToPid(reference.process.pid)
    up.postToPid(reference.process.pid)
    return .submitted
  }

  private func begin() throws {
    guard Thread.isMainThread else { throw MacFocusFailure("unsupported_desktop") }
    guard connected() else { throw MacFocusFailure("session_unavailable") }
    deadline = clock() + 2
    try session()
    // Never prompt here. A future explicit owner settings action may request
    // permission; discovery, prepare and send are observation-only.
    guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
      throw MacFocusFailure("access_denied")
    }
    try modifiers()
  }

  private func session() throws {
    guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any],
          let user = dictionary[kCGSessionUserIDKey as String] as? NSNumber,
          user.uint32Value == geteuid(),
          let onConsole = dictionary[kCGSessionOnConsoleKey as String] as? Bool,
          let login = dictionary[kCGSessionLoginDoneKey as String] as? Bool else {
      throw MacFocusFailure("session_unavailable")
    }
    let facts = MacFocusSessionFacts(user: geteuid(), onConsole: onConsole,
      loginComplete: login, protectedDataAvailable: NSApplication.shared.isProtectedDataAvailable,
      operatingSystem: ProcessInfo.processInfo.operatingSystemVersion)
    guard facts.onConsole, facts.loginComplete, facts.protectedDataAvailable else {
      throw MacFocusFailure("session_unavailable")
    }
    guard supportedSession(facts) else { throw MacFocusFailure("unsupported_desktop") }
  }

  private func foreground() throws -> NSRunningApplication {
    guard let app = NSWorkspace.shared.frontmostApplication, app.isActive,
          !app.isHidden, !app.isTerminated, app.processIdentifier != getpid(),
          app.activationPolicy == .regular else { throw MacFocusFailure("unsupported_target") }
    let refused = ["com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.authorizationhost",
                   "com.apple.LocalAuthentication.UIAgent", "com.apple.CoreServicesUIAgent"]
    guard let bundle = app.bundleIdentifier, !refused.contains(bundle) else {
      throw MacFocusFailure("unsupported_target")
    }
    return app
  }

  private func check(_ reference: Reference) throws {
    try budget()
    try session()
    guard reference.epoch == epoch else { throw MacFocusFailure("session_unavailable") }
    let running = try foreground()
    guard running.processIdentifier == reference.process.pid,
          try MacFocusProcessWitness(running.processIdentifier) == reference.process,
          running.executableURL?.resolvingSymlinksInPath().standardizedFileURL.path == reference.process.path else {
      throw MacFocusFailure("application_changed")
    }
    try reference.executable.recheck()
    let system = AXUIElementCreateSystemWide()
    try timeout(system)
    try timeout(reference.app)
    try timeout(reference.window)
    try timeout(reference.field)
    guard CFEqual(try element(system, kAXFocusedApplicationAttribute), reference.app),
          CFEqual(try element(system, kAXFocusedUIElementAttribute), reference.field),
          CFEqual(try element(reference.app, kAXFocusedUIElementAttribute), reference.field),
          CFEqual(try element(reference.app, kAXFocusedWindowAttribute), reference.window),
          CFEqual(try element(reference.field, kAXWindowAttribute), reference.window) else {
      throw MacFocusFailure("focus_changed")
    }
    for item in [reference.app, reference.window, reference.field] {
      var pid: pid_t = 0
      guard AXUIElementGetPid(item, &pid) == .success, pid == reference.process.pid else {
        throw MacFocusFailure("unsupported_target")
      }
    }
    guard try string(reference.field, kAXRoleAttribute) == kAXTextFieldRole,
          try string(reference.field, kAXSubroleAttribute) == kAXSecureTextFieldSubrole,
          try boolean(reference.field, kAXEnabledAttribute),
          try boolean(reference.field, kAXFocusedAttribute),
          try string(reference.window, kAXRoleAttribute) == kAXWindowRole,
          try !boolean(reference.window, kAXMinimizedAttribute) else {
      throw MacFocusFailure("unsupported_target")
    }
    // Query writability only. Never copy AXValue, selected text, window title or
    // DOM. AXIsEditable is in the SDK's obsolete/unknown group; don't rely on it.
    // Secure fields without a public writable-value declaration remain refused
    // pending a separately reviewed target contract, even if keyboard-editable.
    var settable = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(reference.field, kAXValueAttribute as CFString, &settable) == .success,
          settable.boolValue else { throw MacFocusFailure("unsupported_target") }
    let field = try bounds(reference.field)
    let window = try bounds(reference.window)
    guard window.contains(field), NSScreen.screens.contains(where: { screen in
      guard let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
      return CGDisplayBounds(display.uint32Value).intersects(field)
    }) else { throw MacFocusFailure("unsupported_target") }
    try budget()
    try session()
    try modifiers()
    guard epoch == reference.epoch else { throw MacFocusFailure("session_unavailable") }
  }

  private func modifiers() throws {
    let flags = CGEventSource.flagsState(.combinedSessionState)
    let disallowed: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand,
                                  .maskAlphaShift, .maskSecondaryFn, .maskHelp, .maskNumericPad]
    guard flags.intersection(disallowed).isEmpty else { throw MacFocusFailure("modifier_active") }
  }

  private func budget() throws {
    guard clock() < deadline else { throw MacFocusFailure("target_unavailable") }
  }

  private func timeout(_ element: AXUIElement) throws {
    try budget()
    guard AXUIElementSetMessagingTimeout(element, Float(min(0.15, deadline - clock()))) == .success else {
      throw MacFocusFailure("unsupported_target")
    }
  }

  private func attribute(_ source: AXUIElement, _ name: String) throws -> CFTypeRef {
    try budget()
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(source, name as CFString, &value)
    guard status == .success, let value else {
      throw MacFocusFailure(status == .apiDisabled ? "access_denied" : "unsupported_target")
    }
    return value
  }
  private func element(_ source: AXUIElement, _ name: String) throws -> AXUIElement {
    let value = try attribute(source, name)
    guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw MacFocusFailure("unsupported_target") }
    return unsafeBitCast(value, to: AXUIElement.self)
  }
  private func boolean(_ source: AXUIElement, _ name: String) throws -> Bool {
    let value = try attribute(source, name)
    guard CFGetTypeID(value) == CFBooleanGetTypeID(), let result = value as? Bool else {
      throw MacFocusFailure("unsupported_target")
    }
    return result
  }
  private func string(_ source: AXUIElement, _ name: String) throws -> String {
    guard let value = try attribute(source, name) as? String else { throw MacFocusFailure("unsupported_target") }
    return value
  }
  private func bounds(_ source: AXUIElement) throws -> CGRect {
    let point = try attribute(source, kAXPositionAttribute)
    let size = try attribute(source, kAXSizeAttribute)
    guard CFGetTypeID(point) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
      throw MacFocusFailure("unsupported_target")
    }
    let p = unsafeBitCast(point, to: AXValue.self)
    let s = unsafeBitCast(size, to: AXValue.self)
    var origin = CGPoint.zero
    var extent = CGSize.zero
    guard AXValueGetType(p) == .cgPoint, AXValueGetType(s) == .cgSize,
          AXValueGetValue(p, .cgPoint, &origin), AXValueGetValue(s, .cgSize, &extent),
          origin.x.isFinite, origin.y.isFinite, extent.width.isFinite, extent.height.isFinite,
          extent.width > 0, extent.height > 0 else { throw MacFocusFailure("unsupported_target") }
    return CGRect(origin: origin, size: extent)
  }
}

struct MacFocusProcessWitness: Equatable {
  let pid: pid_t
  let startSeconds: UInt64
  let startMicros: UInt64
  let path: String

  init(_ pid: pid_t) throws {
    var info = proc_bsdinfo()
    let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
    guard count == MemoryLayout.size(ofValue: info), info.pbi_pid == UInt32(pid),
          info.pbi_uid == geteuid(), info.pbi_ruid == getuid(), info.pbi_start_tvsec > 0 else {
      throw MacFocusFailure("application_changed")
    }
    // PROC_PIDPATHINFO_MAXSIZE is a compound macro not imported by Swift.
    var bytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else {
      throw MacFocusFailure("application_changed")
    }
    self.pid = pid
    self.startSeconds = info.pbi_start_tvsec
    self.startMicros = info.pbi_start_tvusec
    self.path = URL(fileURLWithPath: String(cString: bytes)).resolvingSymlinksInPath().standardizedFileURL.path
  }
}

private final class ExecutableWitness {
  let sha256: String
  private let path: String
  private let fd: Int32
  private let metadata: stat

  init(_ path: String, deadline: TimeInterval) throws {
    let opened = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard opened >= 0 else { throw MacFocusFailure("application_changed") }
    var initial = stat()
    guard fstat(opened, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
          initial.st_size > 0, initial.st_size <= 512 * 1024 * 1024 else {
      Darwin.close(opened)
      throw MacFocusFailure("application_changed")
    }
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 65536)
    do {
      var total: Int64 = 0
      while true {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw MacFocusFailure("target_unavailable") }
        let count = Darwin.read(opened, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        guard count >= 0 else { throw MacFocusFailure("application_changed") }
        if count == 0 { break }
        total += Int64(count)
        guard total <= initial.st_size else { throw MacFocusFailure("application_changed") }
        buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])) }
      }
      var after = stat()
      var located = stat()
      guard total == initial.st_size, fstat(opened, &after) == 0, lstat(path, &located) == 0,
            Self.same(initial, after), Self.same(initial, located) else {
        throw MacFocusFailure("application_changed")
      }
    } catch { Darwin.close(opened); throw error }
    self.path = path
    self.fd = opened
    self.metadata = initial
    self.sha256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  deinit { Darwin.close(fd) }

  func recheck() throws {
    var current = stat()
    var located = stat()
    guard fstat(fd, &current) == 0, lstat(path, &located) == 0,
          Self.same(metadata, current), Self.same(metadata, located) else {
      throw MacFocusFailure("application_changed")
    }
  }

  private static func same(_ a: stat, _ b: stat) -> Bool {
    a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode &&
      a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec &&
      a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
      a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
  }
}
