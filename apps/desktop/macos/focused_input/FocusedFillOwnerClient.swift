import Foundation

/// A single owner-to-helper connection. Each RPC has one completion and a
/// deadline. Interruption, malformed replies and ambiguous sends are terminal:
/// never reconnect, retry, or replay input. Private sequence/lease bookkeeping
/// stays here, below Core's durable operation/audit Interface.
final class MacFocusOwnerClient {
  private struct Pending {
    let id = UUID()
    let sending: Bool
    let expected: MacFocusApplication?
    let reply: (MacFocusReply) -> Void
  }
  private let connection: NSXPCConnection
  private let queue = DispatchQueue(label: "org.shijijs.agent-info.focus-client")
  private var ended = false
  private var pending: Pending?
  private var lease: String?
  private var sequence = 0

  init() throws {
    connection = try MacFocusPrivateConnection.open()
    connection.invalidationHandler = { [weak self] in self?.close() }
    connection.interruptionHandler = { [weak self] in self?.close() }
    connection.resume()
  }

  deinit { connection.invalidate() }

  func inspect(reply: @escaping (MacFocusReply) -> Void) {
    request(sending: false, expected: nil, reply: reply) { proxy, completion in proxy.inspect(reply: completion) }
  }

  func prepare(_ application: MacFocusApplication, reply: @escaping (MacFocusReply) -> Void) {
    guard let encoded = try? JSONSerialization.data(withJSONObject: application.wire) else {
      reply(MacFocusReply(state: "refused", errorCode: "application_changed"))
      return
    }
    request(sending: false, expected: application, reply: reply) { proxy, completion in
      proxy.prepare(encoded, reply: completion)
    }
  }

  func send(_ batch: Data, reply: @escaping (MacFocusReply) -> Void) {
    request(sending: true, expected: nil, reply: reply) { [self] proxy, completion in
      // request executes on queue; lease/sequence are never caller-supplied.
      guard let lease else { completion(Data()); return }
      proxy.send(batch, lease: lease, sequence: sequence, reply: completion)
    }
  }

  func close() {
    queue.async { [self] in
      guard !ended else { return }
      ended = true
      lease = nil
      let active = pending
      pending = nil
      connection.invalidate()
      if let active { active.reply(fallback(sending: active.sending)) }
    }
  }

  private func request(sending: Bool, expected: MacFocusApplication?, reply: @escaping (MacFocusReply) -> Void,
                       invoke: @escaping (MacFocusPrivateProtocol, @escaping (Data) -> Void) -> Void) {
    queue.async { [self] in
      guard !ended else { reply(fallback(sending: sending)); return }
      guard pending == nil else { reply(MacFocusReply(state: "refused", errorCode: "busy")); return }
      guard !sending || lease != nil else {
        reply(MacFocusReply(state: "refused", errorCode: "target_unavailable"))
        return
      }
      guard sending || lease == nil else { reply(MacFocusReply(state: "refused", errorCode: "busy")); return }
      let active = Pending(sending: sending, expected: expected, reply: reply)
      pending = active
      let error: (Error) -> Void = { [weak self] _ in self?.finish(active.id, data: nil) }
      guard let proxy = connection.remoteObjectProxyWithErrorHandler(error) as? MacFocusPrivateProtocol else {
        finishOnQueue(active.id, data: nil)
        return
      }
      // No blocking waits on the owner UI thread. A timed-out post is unknown,
      // including when it cannot be determined whether XPC sent the message.
      queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.finishOnQueue(active.id, data: nil) }
      invoke(proxy) { [weak self] data in self?.finish(active.id, data: data) }
    }
  }

  private func finish(_ id: UUID, data: Data?) {
    queue.async { [weak self] in self?.finishOnQueue(id, data: data) }
  }

  private func finishOnQueue(_ id: UUID, data: Data?) {
    guard let active = pending, active.id == id else { return }
    pending = nil
    let decoded = data.flatMap { Self.decode($0) }
    let valid: Bool
    if active.sending {
      valid = decoded.map { ["sent", "refused", "partial", "unknown"].contains($0.state) } ?? false
    } else if let expected = active.expected {
      valid = decoded.map { $0.state == "refused" || ($0.state == "prepared" && $0.application == expected) } ?? false
    } else { valid = decoded.map { $0.state == "ready" || $0.state == "refused" } ?? false }
    let result = valid ? decoded! : fallback(sending: active.sending)
    if result.state == "prepared" {
      lease = result.lease
    } else if result.state == "sent" { sequence += 1 }
    else if result.state != "ready" {
      ended = true
      lease = nil
      connection.invalidate()
    }
    active.reply(result)
  }

  private func fallback(sending: Bool) -> MacFocusReply {
    MacFocusReply(state: sending ? "unknown" : "refused", errorCode: sending ? "fill_unknown" : "session_unavailable")
  }

  private static func decode(_ data: Data) -> MacFocusReply? {
    guard data.count <= 16384,
          let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          value["format"] as? Int == 1, let state = value["state"] as? String else { return nil }
    let keys = Set(value.keys)
    switch state {
    case "ready", "prepared":
      guard keys == (state == "ready" ? ["format", "state", "application"] : ["format", "state", "application", "lease"]),
            let raw = value["application"] as? [String: String], Set(raw.keys) == ["executable", "sha256"],
            let path = raw["executable"], let sha = raw["sha256"],
            let app = try? MacFocusApplication(executable: path, sha256: sha) else { return nil }
      let lease = value["lease"] as? String
      if state == "prepared" && (lease == nil || UUID(uuidString: lease!) == nil) { return nil }
      return MacFocusReply(state: state, application: app, lease: lease)
    case "sent":
      return keys == ["format", "state"] ? MacFocusReply(state: state) : nil
    case "refused", "partial", "unknown":
      let allowed = ["access_denied", "session_unavailable", "unsupported_desktop", "desktop_locked",
        "unsupported_target", "focus_changed", "application_changed", "modifier_active", "busy",
        "input_rejected", "unsupported_secret", "target_unavailable", "fill_unknown"]
      guard keys == ["format", "state", "errorCode"], let code = value["errorCode"] as? String,
            allowed.contains(code), state != "unknown" || code == "fill_unknown" else { return nil }
      return MacFocusReply(state: state, errorCode: code)
    default: return nil
    }
  }
}

/// Short-lived authenticated permission connection. It never owns a target or
/// retries an RPC; the bridge retains it until completion or app shutdown.
final class MacFocusPermissionClient {
  private let connection: NSXPCConnection
  private let queue = DispatchQueue(label: "org.shijijs.agent-info.focus-permissions")
  private var completion: ((MacFocusPermissionStatus) -> Void)?
  private var ended = false

  init() throws { connection = try MacFocusPrivateConnection.open() }
  deinit { connection.invalidate() }

  func query(prompt: Bool, reply: @escaping (MacFocusPermissionStatus) -> Void) {
    queue.async { [self] in
      guard !ended, completion == nil else { reply(.unavailable); return }
      completion = reply
      connection.invalidationHandler = { [weak self] in self?.finish(nil) }
      connection.interruptionHandler = { [weak self] in self?.finish(nil) }
      connection.resume()
      guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in self?.finish(nil) })
        as? MacFocusPrivateProtocol else { finish(nil); return }
      queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.finish(nil) }
      let received: (Data) -> Void = { [weak self] data in self?.finish(data) }
      if prompt { proxy.requestPermission(reply: received) }
      else { proxy.permissions(reply: received) }
    }
  }

  func close() { finish(nil) }
  private func finish(_ data: Data?) {
    queue.async { [self] in
      guard !ended else { return }
      ended = true
      let reply = completion
      completion = nil
      connection.invalidate()
      reply?(data.flatMap(MacFocusPermissionStatus.decode) ?? .unavailable)
    }
  }
}
