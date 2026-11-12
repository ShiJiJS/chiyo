import Foundation

/// Candidate helper listener. ServiceMain retains this object and enters its
/// run loop. Runner does not link this file; only the separately built private
/// XPC executable owns system observation/input code.
final class MacFocusPrivateService: NSObject, NSXPCListenerDelegate {
  private let identity: MacFocusSignedPair
  private let listener: NSXPCListener
  private let supportedSession: (MacFocusSessionFacts) -> Bool
  private let lock = NSLock()
  private var sessions: [UUID: MacFocusPrivateSession] = [:]

  init(supportedSession: @escaping (MacFocusSessionFacts) -> Bool = MacFocusSessionFacts.supportsLocalConsole) throws {
    self.identity = try MacFocusSignedPair.load(isHelper: true)
    self.listener = .service()
    self.supportedSession = supportedSession
    super.init()
    // service() listeners do not support listener-level requirements (Foundation
    // asserts/crashes). Apply the exact requirement to each accepted connection
    // below, before resume or any exported RPC can execute.
    listener.delegate = self
  }

  func resume() { listener.resume() }

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
    guard connection.effectiveUserIdentifier == geteuid(),
          let process = try? MacFocusProcessWitness(connection.processIdentifier),
          process.path == identity.ownerExecutable else { return false }
    // Set this before resume: authentication belongs
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

  func permissions(reply: @escaping (Data) -> Void) { permissionStatus(prompt: false, reply: reply) }
  func requestPermission(reply: @escaping (Data) -> Void) { permissionStatus(prompt: true, reply: reply) }

  private func permissionStatus(prompt: Bool, reply: @escaping (Data) -> Void) {
    DispatchQueue.main.async { [self] in
      let result = live() ? SystemMacFocusEnvironment.permissions(prompt: prompt) : .unavailable
      reply((try? JSONSerialization.data(withJSONObject: result.wire)) ?? Data())
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
