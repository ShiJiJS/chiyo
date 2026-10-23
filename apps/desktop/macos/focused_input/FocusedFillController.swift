import Foundation

/// Helper-side native input module. Core remains responsible for private session,
/// grant/version/expiry checks and durable intent/checked/released audits BEFORE
/// each call to send. This module never accepts a secret on prepare/discovery.
///
/// Slow target observation happens outside the lock. close() may cancel it;
/// the final live-lease check and posting one bounded batch share the lock.
final class MacFocusedFillController {
  private final class Lease {
    let token = UUID().uuidString
    let target: MacFocusTarget
    let started: TimeInterval
    var posted = false
    var nextSequence = 0
    var lastReply: MacFocusReply?
    init(_ target: MacFocusTarget, _ started: TimeInterval) {
      self.target = target
      self.started = started
    }
  }

  private let environment: MacFocusEnvironment
  private let gate: MacFocusSerialGate
  private let connected: () -> Bool
  private let clock: () -> TimeInterval
  private let lifetime: TimeInterval
  private let lock = NSLock()
  private var lease: Lease?
  private var expiry: DispatchSourceTimer?
  private var preparing = false
  private var closed = false

  init(environment: MacFocusEnvironment, gate: MacFocusSerialGate,
       connected: @escaping () -> Bool,
       clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
       lifetime: TimeInterval = 60) {
    precondition(lifetime > 0 && lifetime <= 60)
    self.environment = environment
    self.gate = gate
    self.connected = connected
    self.clock = clock
    self.lifetime = lifetime
  }

  deinit { close() }

  func inspect() -> MacFocusReply { capture(expected: nil) }
  func prepare(_ application: MacFocusApplication) -> MacFocusReply { capture(expected: application) }

  private func capture(expected: MacFocusApplication?) -> MacFocusReply {
    lock.lock()
    expireLocked()
    guard !closed && connected() else { lock.unlock(); return refused("session_unavailable") }
    guard !preparing && lease == nil else { lock.unlock(); return refused("busy") }
    do { try gate.acquire() }
    catch { lock.unlock(); return refused(code(error)) }
    preparing = true
    let start = clock()
    lock.unlock()

    let observed: Result<MacFocusTarget, Error>
    do {
      let target = try environment.capture()
      if let expected, target.application != expected { throw MacFocusFailure("application_changed") }
      try environment.recheck(target)
      observed = .success(target)
    } catch { observed = .failure(error) }

    lock.lock()
    defer { lock.unlock() }
    preparing = false
    guard !closed && connected() && clock() >= start && clock() - start < 4 else {
      gate.release()
      return refused("session_unavailable")
    }
    switch observed {
    case .failure(let error):
      gate.release()
      return refused(code(error))
    case .success(let target):
      guard expected != nil else {
        gate.release()
        return MacFocusReply(state: "ready", application: target.application)
      }
      let prepared = Lease(target, clock())
      lease = prepared
      let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
      timer.schedule(deadline: .now() + lifetime)
      timer.setEventHandler { [weak self, weak prepared] in
        guard let self, let prepared else { return }
        self.lock.lock()
        defer { self.lock.unlock() }
        if self.lease === prepared { self.releaseLocked() }
      }
      expiry = timer
      timer.resume()
      return MacFocusReply(state: "prepared", application: target.application, lease: prepared.token)
    }
  }

  func send(_ data: Data, lease token: String, sequence: Int) -> MacFocusReply {
    lock.lock()
    expireLocked()
    guard !closed && connected() else {
      releaseLocked()
      lock.unlock()
      return refused("session_unavailable")
    }
    guard let current = lease, current.token == token else {
      lock.unlock()
      return refused("target_unavailable")
    }
    if sequence == current.nextSequence - 1, let reply = current.lastReply {
      lock.unlock()
      return reply // A repeated private RPC does not post the batch again.
    }
    guard sequence >= 0 && sequence <= 1024 && sequence == current.nextSequence else {
      let reply = failureLocked(current, "input_rejected")
      lock.unlock()
      return reply
    }
    var units: [UInt16] = []
    defer { units.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) } }
    if !data.isEmpty && data.count <= 32 && data.count % 2 == 0 {
      units = data.withUnsafeBytes { bytes in
        stride(from: 0, to: bytes.count, by: 2).map {
          UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8
        }
      }
    }
    guard valid(units) else {
      let reply = failureLocked(current, "unsupported_secret")
      lock.unlock()
      return reply
    }
    lock.unlock()

    let checked: Result<Void, Error>
    do { try environment.recheck(current.target); checked = .success(()) }
    catch { checked = .failure(error) }

    lock.lock()
    defer { lock.unlock() }
    expireLocked()
    guard !closed && connected() && lease === current else {
      return current.posted ? MacFocusReply(state: "partial", errorCode: "session_unavailable")
        : refused("session_unavailable")
    }
    if sequence == current.nextSequence - 1, let reply = current.lastReply { return reply }
    guard sequence == current.nextSequence else { return failureLocked(current, "input_rejected") }
    if case .failure(let error) = checked { return failureLocked(current, code(error)) }
    do {
      switch try environment.post(units, to: current.target) {
      case .submitted:
        current.posted = true
        current.nextSequence += 1
        let reply = MacFocusReply(state: "sent")
        current.lastReply = reply
        return reply
      case .refused(let error):
        return failureLocked(current, safe(error))
      case .unknown:
        releaseLocked()
        return MacFocusReply(state: "unknown", errorCode: "fill_unknown")
      }
    } catch {
      // A throwing sender may already have posted part/all of this batch.
      releaseLocked()
      return MacFocusReply(state: "unknown", errorCode: "fill_unknown")
    }
  }

  func close() {
    lock.lock()
    defer { lock.unlock() }
    closed = true
    releaseLocked()
    // A pending capture retains its own gate until it observes cancellation.
  }

  private func expireLocked() {
    if let current = lease, clock() < current.started || clock() - current.started >= lifetime {
      releaseLocked()
    }
  }
  private func releaseLocked() {
    expiry?.cancel()
    expiry = nil
    if lease != nil { lease = nil; gate.release() }
  }
  private func failureLocked(_ current: Lease, _ error: String) -> MacFocusReply {
    releaseLocked()
    return current.posted ? MacFocusReply(state: "partial", errorCode: error) : refused(error)
  }
  private func refused(_ error: String) -> MacFocusReply { MacFocusReply(state: "refused", errorCode: error) }
  private func code(_ error: Error) -> String { safe((error as? MacFocusFailure)?.code ?? "unsupported_target") }
  private func safe(_ code: String) -> String {
    ["access_denied", "session_unavailable", "unsupported_desktop", "desktop_locked",
     "unsupported_target", "focus_changed", "application_changed", "modifier_active",
     "busy", "input_rejected", "unsupported_secret", "target_unavailable"].contains(code)
      ? code : "unsupported_target"
  }
  private func valid(_ units: [UInt16]) -> Bool {
    guard !units.isEmpty && units.count <= 16 else { return false }
    var i = 0
    while i < units.count {
      let value = units[i]
      if value < 32 || value == 127 { return false }
      if (0xd800...0xdbff).contains(value) {
        guard i + 1 < units.count, (0xdc00...0xdfff).contains(units[i + 1]) else { return false }
        i += 1
      } else if (0xdc00...0xdfff).contains(value) { return false }
      i += 1
    }
    return true
  }
}
