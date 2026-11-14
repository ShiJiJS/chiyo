import Foundation

/// Reservations cover all scopes and owner connections in this helper process.
/// Capture is main-thread-only, but final owner destruction may release on XPC
/// invalidation threads; all shared dictionary access is synchronized. Different random target IDs cannot hide one AX object.
private final class NativeReservations {
  static let shared = NativeReservations()
  private let lock = NSLock()
  private var values: [UUID: MacNativeBackgroundCandidate] = [:]
  func reserve(_ id: UUID, _ candidate: MacNativeBackgroundCandidate, environment: MacNativeBackgroundEnvironment) throws {
    lock.lock(); defer { lock.unlock() }
    guard !values.values.contains(where: { environment.sameTarget(candidate, $0) }) else {
      throw MacNativeBackgroundFailure.busy
    }
    values[id] = candidate
  }
  func release(_ id: UUID) { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: id) }
}

/// One authenticated private-chat connection owns this main-thread registry.
/// Targets and operation tickets have separate lifetimes. Nothing is persisted
/// or recoverable across helper/connection lifetimes.
final class MacNativeBackgroundController {
  private final class Target {
    let candidate: MacNativeBackgroundCandidate
    let application: MacFocusApplication
    var expires: TimeInterval
    var retainedAuthorization: (() -> Bool)?
    init(_ candidate: MacNativeBackgroundCandidate, _ application: MacFocusApplication, _ expires: TimeInterval) {
      self.candidate = candidate; self.application = application; self.expires = expires
    }
  }
  private struct Ticket {
    let targetID: UUID
    let expires: TimeInterval
  }
  let helperInstanceID = UUID()
  private let environment: MacNativeBackgroundEnvironment
  private let clock: () -> TimeInterval
  private let discoveryLifetime: TimeInterval
  private let preparationLifetime: TimeInterval
  private let connected: () -> Bool
  private var targets: [UUID: Target] = [:]
  private var tickets: [UUID: Ticket] = [:]
  private var scope: UUID?
  private var timer: DispatchSourceTimer?
  private var closed = false
  private var lastNow: TimeInterval = 0

  init(environment: MacNativeBackgroundEnvironment, connected: @escaping () -> Bool,
       clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
       discoveryLifetime: TimeInterval = 300, preparationLifetime: TimeInterval = 30) {
    precondition(discoveryLifetime > 0 && discoveryLifetime <= 300)
    precondition(preparationLifetime > 0 && preparationLifetime <= 30)
    self.environment = environment; self.connected = connected; self.clock = clock
    self.discoveryLifetime = discoveryLifetime; self.preparationLifetime = preparationLifetime
  }
  deinit { timer?.cancel(); for id in tickets.keys { NativeReservations.shared.release(id) } }

  func discover(_ access: MacNativeBackgroundAccess) throws -> [MacNativeBackgroundDescriptor] {
    try available(access)
    let began = clock()
    let found = try environment.discover(access.application)
    try available(access)
    guard clock() >= began, clock() - began < 4 else { throw MacNativeBackgroundFailure.expired }
    guard found.count <= 64,
          Set(found.map { $0.descriptor.candidateID }).count == found.count else { throw MacNativeBackgroundFailure.ambiguousTarget }
    guard targets.values.filter({ $0.retainedAuthorization == nil }).count + found.count <= 64,
          found.allSatisfy({ targets[$0.descriptor.candidateID] == nil }) else { throw MacNativeBackgroundFailure.busy }
    for candidate in found {
      targets[candidate.descriptor.candidateID] = Target(candidate, access.application, clock() + discoveryLifetime)
    }
    if timer == nil {
      let expiry = DispatchSource.makeTimerSource(queue: .main)
      expiry.schedule(deadline: .now() + 1, repeating: 1)
      expiry.setEventHandler { [weak self] in self?.expire() }
      timer = expiry; expiry.resume()
    }
    return found.map { $0.descriptor }
  }

  /// Trusted owner only: until is monotonic time from the validated grant, never
  /// a caller-supplied TTL. The callback reflects grant/version/revocation.
  func retain(_ targetID: UUID, until: TimeInterval, access: MacNativeBackgroundAccess,
              grantIsValid: @escaping () -> Bool) throws {
    let target = try active(targetID, access)
    guard until.isFinite, until > clock(), grantIsValid() else { throw MacNativeBackgroundFailure.unauthorized }
    try retentionCapacity(target)
    try environment.recheck(target.candidate)
    _ = try active(targetID, access)
    target.expires = until; target.retainedAuthorization = grantIsValid
  }

  func capture(_ targetID: UUID, access: MacNativeBackgroundAccess) throws -> UUID {
    let target = try active(targetID, access)
    guard !tickets.values.contains(where: { $0.targetID == targetID }) else { throw MacNativeBackgroundFailure.busy }
    do { try environment.recheck(target.candidate); _ = try active(targetID, access) }
    catch { targets.removeValue(forKey: targetID); throw error }
    let token = UUID()
    try NativeReservations.shared.reserve(token, target.candidate, environment: environment)
    tickets[token] = Ticket(targetID: targetID, expires: min(target.expires, clock() + preparationLifetime))
    return token
  }

  /// prepare(expected:nil) binds a pending request without authorizing a write.
  /// References remain bounded and die with the authenticated host connection.
  func promote(_ targetID: UUID, access: MacNativeBackgroundAccess) throws {
    let target = try active(targetID, access)
    try retentionCapacity(target)
    target.expires = .greatestFiniteMagnitude
    target.retainedAuthorization = { true }
  }

  func release(_ targetID: UUID, access: MacNativeBackgroundAccess) throws {
    try available(access)
    if let target = targets[targetID], target.application != access.application { throw MacNativeBackgroundFailure.unauthorized }
    targets.removeValue(forKey: targetID)
    for (id, ticket) in tickets where ticket.targetID == targetID { NativeReservations.shared.release(id) }
    tickets = tickets.filter { $0.value.targetID != targetID }
  }

  /// Idempotent prepare.close; the target survives for later approved operations.
  func closePreparation(_ token: UUID) {
    precondition(Thread.isMainThread)
    tickets.removeValue(forKey: token)
    NativeReservations.shared.release(token)
  }

  /// Whole-value one-shot ticket. Owner beforeDispatch rechecks the durable
  /// operation/grant. Native write then performs another local target recheck.
  func write(_ data: Data, lease token: UUID, access: MacNativeBackgroundAccess,
             beforeDispatch: () -> Bool) -> MacNativeBackgroundWriteResult {
    guard Thread.isMainThread else { return .refused(.wrongThread) }
    do { try available(access) }
    catch { return .refused(failure(error)) }
    guard let ticket = tickets.removeValue(forKey: token) else { return .refused(.consumed) }
    defer { NativeReservations.shared.release(token) }
    let target: Target
    do {
      target = try active(ticket.targetID, access)
      guard clock() < ticket.expires else { throw MacNativeBackgroundFailure.expired }
    } catch { return .refused(failure(error)) }
    guard !data.isEmpty, data.count <= 16384, let secret = String(data: data, encoding: .utf8),
          !secret.isEmpty, secret.utf16.count <= 4096,
          !secret.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return .refused(.unsupportedSecret) }
    do { try environment.recheck(target.candidate); _ = try active(ticket.targetID, access) }
    catch { targets.removeValue(forKey: ticket.targetID); return .refused(failure(error)) }
    guard beforeDispatch() else { return .refused(.unauthorized) }
    return environment.write(secret, to: target.candidate, authorized: {
      !self.closed && self.connected() && self.clock() < ticket.expires && self.clock() < target.expires &&
        access.isAuthorized() && (target.retainedAuthorization?() ?? true)
    })
  }

  func close() {
    precondition(Thread.isMainThread)
    closed = true; targets.removeAll(); for id in tickets.keys { NativeReservations.shared.release(id) }; tickets.removeAll(); timer?.cancel(); timer = nil
  }
  private func active(_ id: UUID, _ access: MacNativeBackgroundAccess) throws -> Target {
    try available(access)
    guard let target = targets[id], target.application == access.application else { throw MacNativeBackgroundFailure.targetUnavailable }
    return target
  }
  private func retentionCapacity(_ target: Target) throws {
    guard target.retainedAuthorization != nil || targets.values.filter({ $0.retainedAuthorization != nil }).count < 256 else {
      throw MacNativeBackgroundFailure.busy
    }
  }
  private func available(_ access: MacNativeBackgroundAccess) throws {
    guard Thread.isMainThread else { throw MacNativeBackgroundFailure.wrongThread }
    guard !closed, connected() else { close(); throw MacNativeBackgroundFailure.sessionUnavailable }
    guard access.isAuthorized() else { throw MacNativeBackgroundFailure.unauthorized }
    if let scope { guard scope == access.scopeID else { throw MacNativeBackgroundFailure.unauthorized } }
    else { scope = access.scopeID }
    expire()
  }
  private func expire() {
    let now = clock()
    guard now.isFinite, now >= lastNow else {
      targets.removeAll(); for id in tickets.keys { NativeReservations.shared.release(id) }; tickets.removeAll(); return
    }
    lastNow = now
    targets = targets.filter { now < $0.value.expires && ($0.value.retainedAuthorization?() ?? true) }
    for (id, ticket) in tickets where now >= ticket.expires || targets[ticket.targetID] == nil { NativeReservations.shared.release(id) }
    tickets = tickets.filter { now < $0.value.expires && targets[$0.value.targetID] != nil }
  }
  private func failure(_ error: Error) -> MacNativeBackgroundFailure {
    (error as? MacNativeBackgroundFailure) ?? .targetUnavailable
  }
}
