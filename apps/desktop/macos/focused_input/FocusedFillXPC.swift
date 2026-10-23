import AppKit
import Foundation
import Security

/// A private embedded service only. No Mach service, LaunchAgent, arbitrary
/// target PID, event kind or executable can be supplied by an Agent.
@objc(MacFocusedFillPrivateV1)
protocol MacFocusPrivateProtocol {
  func inspect(reply: @escaping (Data) -> Void)
  func prepare(_ application: Data, reply: @escaping (Data) -> Void)
  func send(_ batch: Data, lease: String, sequence: Int, reply: @escaping (Data) -> Void)
}

struct MacFocusSignedPair {
  static let serviceName = "org.shijijs.AgentInfoFocusedFill"
  let ownerExecutable: String
  let ownerRequirement: String
  let helperRequirement: String

  /// Derive both identities from the sealed enclosing package, not from a
  /// connection message, preferences, environment or caller-provided path.
  static func load(isHelper: Bool) throws -> MacFocusSignedPair {
    let running = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
    let ownerURL = isHelper
      ? running.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      : running
    let helperURL = ownerURL.appendingPathComponent("Contents/XPCServices/\(serviceName).xpc")
    guard ownerURL.pathExtension == "app", running == (isHelper ? helperURL : ownerURL),
          let owner = Bundle(url: ownerURL), owner.bundleIdentifier == "com.example.infoDesktop",
          let helper = Bundle(url: helperURL), helper.bundleIdentifier == serviceName,
          let ownerExecutable = owner.executableURL?.resolvingSymlinksInPath().standardizedFileURL,
          let helperExecutable = helper.executableURL?.resolvingSymlinksInPath().standardizedFileURL,
          ownerExecutable.path.hasPrefix(ownerURL.appendingPathComponent("Contents/MacOS").path + "/"),
          helperExecutable.path.hasPrefix(helperURL.appendingPathComponent("Contents/MacOS").path + "/"),
          try MacFocusProcessWitness(getpid()).path == (isHelper ? helperExecutable.path : ownerExecutable.path) else {
      throw MacFocusFailure("application_changed")
    }
    let pair = try MacFocusSignedPair(ownerExecutable: ownerExecutable.path,
      ownerRequirement: requirement(ownerURL), helperRequirement: requirement(helperURL))
    var current: SecCode?
    var expected: SecRequirement?
    let expression = isHelper ? pair.helperRequirement : pair.ownerRequirement
    guard SecCodeCopySelf([], &current) == errSecSuccess, let current,
          SecRequirementCreateWithString(expression as CFString, [], &expected) == errSecSuccess,
          let expected, SecCodeCheckValidity(current, [], expected) == errSecSuccess else {
      throw MacFocusFailure("application_changed")
    }
    return pair
  }

  private static func requirement(_ url: URL) throws -> String {
    var code: SecStaticCode?
    let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
          SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else {
      throw MacFocusFailure("application_changed")
    }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(code, [], &information) == errSecSuccess,
          let values = information as? [String: Any],
          let digest = values[kSecCodeInfoUnique as String] as? Data, digest.count == 20 else {
      throw MacFocusFailure("application_changed")
    }
    // Exact native-architecture CodeDirectory hash also works with the current
    // development ad-hoc signing model. It is deliberately stronger than just
    // a bundle identifier or a broad designated requirement. Another package
    // version requires a new connection; no automatic cross-version recovery.
    let expression = "cdhash H\"" + digest.map { String(format: "%02x", $0) }.joined() + "\""
    var checked: SecRequirement?
    guard SecRequirementCreateWithString(expression as CFString, [], &checked) == errSecSuccess,
          let checked, SecStaticCodeCheckValidity(code, flags, checked) == errSecSuccess else {
      throw MacFocusFailure("application_changed")
    }
    return expression
  }
}

/// Candidate helper entry point: a future signed XPC executable must retain
/// this object, call resume(), and run its main loop. Nothing in Runner currently
/// constructs it; no helper is installed or launched by adding this source.
final class MacFocusPrivateService: NSObject, NSXPCListenerDelegate {
  private let identity: MacFocusSignedPair
  private let listener: NSXPCListener
  private let supportedSession: (MacFocusSessionFacts) -> Bool
  private let lock = NSLock()
  private var sessions: [UUID: MacFocusPrivateSession] = [:]

  init(supportedSession: @escaping (MacFocusSessionFacts) -> Bool = { _ in false }) throws {
    self.identity = try MacFocusSignedPair.load(isHelper: true)
    self.listener = .service()
    self.supportedSession = supportedSession
    super.init()
    listener.setConnectionCodeSigningRequirement(identity.ownerRequirement)
    listener.delegate = self
  }

  func resume() { listener.resume() }

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
    guard connection.effectiveUserIdentifier == geteuid(),
          let process = try? MacFocusProcessWitness(connection.processIdentifier),
          process.path == identity.ownerExecutable else { return false }
    // Set this before resume as well as on the listener: authentication belongs
    // to the actual XPC peer, never to a PID/identifier claimed in a request.
    connection.setCodeSigningRequirement(identity.ownerRequirement)
    let id = UUID()
    let session = MacFocusPrivateSession(connection: connection, owner: process,
      supportedSession: supportedSession)
    lock.lock()
    sessions[id] = session
    lock.unlock()
    let ended = { [weak self, weak session] in
      session?.close()
      guard let self else { return }
      self.lock.lock()
      self.sessions.removeValue(forKey: id)
      self.lock.unlock()
    }
    connection.invalidationHandler = ended
    // Interruption is terminal, even if XPC could reconnect the service later.
    connection.interruptionHandler = { [weak connection] in ended(); connection?.invalidate() }
    connection.exportedInterface = NSXPCInterface(with: MacFocusPrivateProtocol.self)
    connection.exportedObject = session
    connection.resume()
    return true
  }
}

private final class MacFocusPrivateSession: NSObject, MacFocusPrivateProtocol {
  private weak var connection: NSXPCConnection?
  private let owner: MacFocusProcessWitness
  private let supportedSession: (MacFocusSessionFacts) -> Bool
  private let state = NSLock()
  private var ended = false
  private var controller: MacFocusedFillController?
  private var pending = false
  private var ownerExit: DispatchSourceProcess?

  init(connection: NSXPCConnection, owner: MacFocusProcessWitness,
       supportedSession: @escaping (MacFocusSessionFacts) -> Bool) {
    self.connection = connection
    self.owner = owner
    self.supportedSession = supportedSession
    super.init()
    let watch = DispatchSource.makeProcessSource(identifier: owner.pid, eventMask: .exit, queue: .global(qos: .utility))
    watch.setEventHandler { [weak self] in self?.close(); self?.connection?.invalidate() }
    ownerExit = watch
    watch.resume()
  }

  deinit { close() }

  func close() {
    state.lock()
    ended = true
    let active = controller
    state.unlock()
    ownerExit?.cancel()
    active?.close()
  }

  private func live() -> Bool {
    state.lock()
    let open = !ended
    state.unlock()
    return open && connection != nil && (try? MacFocusProcessWitness(owner.pid)) == owner
  }

  private func perform(_ reply: @escaping (Data) -> Void,
                       action: @escaping (MacFocusedFillController) -> MacFocusReply) {
    let received = ProcessInfo.processInfo.systemUptime
    state.lock()
    guard !ended, !pending else {
      let code = ended ? "session_unavailable" : "busy"
      state.unlock()
      respond(MacFocusReply(state: "refused", errorCode: code), reply)
      return
    }
    pending = true
    state.unlock()
    DispatchQueue.main.async { [self] in
      state.lock()
      let cancelled = ended
      state.unlock()
      let result: MacFocusReply
      if cancelled || !live() || ProcessInfo.processInfo.systemUptime - received >= 0.15 {
        result = MacFocusReply(state: "refused", errorCode: "session_unavailable")
      } else {
        state.lock()
        if controller == nil && !ended {
          controller = MacFocusedFillController(
            environment: SystemMacFocusEnvironment(supportedSession: supportedSession,
              connected: { [weak self] in self?.live() ?? false }),
            gate: MacFocusFileGate(), connected: { [weak self] in self?.live() ?? false })
        }
        let active = controller
        state.unlock()
        result = active.map(action) ?? MacFocusReply(state: "refused", errorCode: "session_unavailable")
      }
      state.lock()
      pending = false
      state.unlock()
      respond(result, reply)
    }
  }

  func inspect(reply: @escaping (Data) -> Void) { perform(reply) { $0.inspect() } }

  func prepare(_ application: Data, reply: @escaping (Data) -> Void) {
    guard application.count <= 8192,
          let value = try? JSONSerialization.jsonObject(with: application) as? [String: String],
          Set(value.keys) == ["executable", "sha256"],
          let path = value["executable"], let sha = value["sha256"],
          let application = try? MacFocusApplication(executable: path, sha256: sha) else {
      respond(MacFocusReply(state: "refused", errorCode: "application_changed"), reply)
      return
    }
    perform(reply) { $0.prepare(application) }
  }

  func send(_ batch: Data, lease: String, sequence: Int, reply: @escaping (Data) -> Void) {
    guard lease.utf8.count <= 64, batch.count <= 32 else {
      respond(MacFocusReply(state: "refused", errorCode: "input_rejected"), reply)
      return
    }
    perform(reply) { $0.send(batch, lease: lease, sequence: sequence) }
  }

  private func respond(_ value: MacFocusReply, _ reply: (Data) -> Void) {
    // The reply DTO contains no secret, native target reference, input length or
    // native error description. Its shape is shared with the owner client only.
    reply((try? JSONSerialization.data(withJSONObject: value.wire)) ?? Data())
  }
}

/// Owner-native connection factory. A future bridge owns one connection per
/// inspect/prepare operation, invalidates it on close/timeout, and must never
/// reconnect/replay a batch after an ambiguous result.
enum MacFocusPrivateConnection {
  static func open() throws -> NSXPCConnection {
    let identity = try MacFocusSignedPair.load(isHelper: false)
    let connection = NSXPCConnection(serviceName: MacFocusSignedPair.serviceName)
    connection.setCodeSigningRequirement(identity.helperRequirement)
    connection.remoteObjectInterface = NSXPCInterface(with: MacFocusPrivateProtocol.self)
    // The bridge must install terminal interruption/invalidation handlers and a
    // bounded reply watchdog before resuming. Constructing does not start XPC.
    return connection
  }
}
