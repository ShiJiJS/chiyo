import Foundation

/// Helper-private JSON adapter. Only the existing signed-owner XPC session may
/// instantiate/call it. Scope isolates references and is NEVER authentication.
final class MacNativeBackgroundWire {
  private static let instance = UUID().uuidString
  private final class Record {
    let target: [String: Any]
    let application: MacFocusApplication
    let created = ProcessInfo.processInfo.systemUptime
    var promoted = false
    init(_ target: [String: Any], _ application: MacFocusApplication) { self.target = target; self.application = application }
  }
  private final class Scope {
    let controller: MacNativeBackgroundController
    let environment: SystemMacNativeBackgroundEnvironment
    let id = UUID()
    var records: [String: Record] = [:]
    var leases: [String: (target: String, expires: TimeInterval)] = [:]
    init(_ live: @escaping () -> Bool) {
      environment = SystemMacNativeBackgroundEnvironment()
      controller = MacNativeBackgroundController(environment: environment, connected: live)
    }
  }
  private let live: () -> Bool
  private var scopes: [String: Scope] = [:]
  private var closed = false
  init(live: @escaping () -> Bool) { self.live = live }
  func close() {
    precondition(Thread.isMainThread)
    closed = true
    for scope in scopes.values { scope.controller.close() }
    scopes.removeAll()
  }
  func handle(_ data: Data) -> Data {
    let response: [String: Any]
    do {
      guard Thread.isMainThread, live(), !closed else { throw MacNativeBackgroundFailure.sessionUnavailable }
      guard data.count <= 131072,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["format"] as? Int == 1, let command = object["command"] as? String else {
        throw MacNativeBackgroundFailure.unsupportedTarget
      }
      if command == "dispose" {
        guard Set(object.keys) == ["format", "command"] else { throw MacNativeBackgroundFailure.unsupportedTarget }
        close()
        return (try? JSONSerialization.data(withJSONObject: ["format": 1, "state": "disposed"])) ?? Data()
      }
      guard let scopeID = object["scope"] as? String,
            scopeID.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
        throw MacNativeBackgroundFailure.unauthorized
      }
      let scope: Scope
      if let existing = scopes[scopeID] { scope = existing }
      else {
        guard command == "discover", scopes.count < 32 else { throw MacNativeBackgroundFailure.targetUnavailable }
        scope = Scope(live); scopes[scopeID] = scope
      }
      scope.records = scope.records.filter { $0.value.promoted || ProcessInfo.processInfo.systemUptime - $0.value.created < 300 }
      scope.leases = scope.leases.filter { $0.value.expires > ProcessInfo.processInfo.systemUptime && scope.records[$0.value.target] != nil }
      let keys = Set(object.keys)
      let base: Set<String> = ["format", "command", "scope"]
      func access(_ record: Record) -> MacNativeBackgroundAccess {
        MacNativeBackgroundAccess(scopeID: scope.id, application: record.application, isAuthorized: live)
      }
      switch command {
      case "discover":
        try scope.environment.checkAvailability()
        guard keys == base.union(["appId"]) || keys == base.union(["appId", "windowId"]),
              let appID = object["appId"] as? String, !appID.isEmpty, appID.utf8.count <= 4096,
              object["windowId"] == nil || object["windowId"] is String else { throw MacNativeBackgroundFailure.unsupportedTarget }
        let application = try scope.environment.application(appID)
        let allowed = MacNativeBackgroundAccess(scopeID: scope.id, application: application, isAuthorized: live)
        let candidates = try scope.controller.discover(allowed)
        var targets: [[String: Any]] = []
        for item in candidates {
          let windowID = item.windowIdentifier
          if let selected = object["windowId"] as? String, selected != windowID { continue }
          let snapshot: [String: Any] = ["targetId": item.candidateID.uuidString,
            "helperInstanceId": Self.instance, "platform": "macos", "application": application.wire,
            "appId": appID, "appName": MacNativeBackgroundCapability.limit(URL(fileURLWithPath: application.executable).lastPathComponent, units: 256),
            "windowId": windowID, "windowTitle": item.windowTitle,
            "fieldLabel": item.fieldLabel, "controlKind": MacNativeBackgroundCapability.controlKind]
          scope.records[item.candidateID.uuidString] = Record(snapshot, application)
          targets.append(snapshot)
        }
        if object["windowId"] != nil && targets.isEmpty { throw MacNativeBackgroundFailure.targetUnavailable }
        response = ["format": 1, "state": "ready", "targets": targets]
      case "prepare":
        guard keys == base.union(["targetId"]) || keys == base.union(["targetId", "expected"]),
              let id = object["targetId"] as? String, let targetID = UUID(uuidString: id),
              let record = scope.records[id] else { throw MacNativeBackgroundFailure.targetUnavailable }
        if let expected = object["expected"] {
          guard let expected = expected as? [String: Any], NSDictionary(dictionary: expected).isEqual(to: record.target) else {
            throw MacNativeBackgroundFailure.targetChanged
          }
        }
        guard scope.leases.count < 256 else { throw MacNativeBackgroundFailure.busy }
        let allowed = access(record)
        let lease = try scope.controller.capture(targetID, access: allowed)
        do { try scope.controller.promote(targetID, access: allowed) }
        catch { scope.controller.closePreparation(lease); throw error }
        record.promoted = true
        scope.leases[lease.uuidString] = (id, ProcessInfo.processInfo.systemUptime + 30)
        response = ["format": 1, "state": "prepared", "target": record.target, "leaseId": lease.uuidString]
      case "close":
        guard keys == base.union(["leaseId"]), let id = object["leaseId"] as? String,
              let lease = UUID(uuidString: id) else { throw MacNativeBackgroundFailure.targetUnavailable }
        scope.leases.removeValue(forKey: id); scope.controller.closePreparation(lease)
        response = ["format": 1, "state": "closed"]
      case "release":
        guard keys == base.union(["targetId"]), let id = object["targetId"] as? String,
              let targetID = UUID(uuidString: id) else { throw MacNativeBackgroundFailure.targetUnavailable }
        if let record = scope.records[id] { try scope.controller.release(targetID, access: access(record)) }
        scope.records.removeValue(forKey: id); scope.leases = scope.leases.filter { $0.value.target != id }
        response = ["format": 1, "state": "released"]
      case "setValue":
        guard keys == base.union(["leaseId", "bytes"]), let id = object["leaseId"] as? String,
              let lease = UUID(uuidString: id), let ticket = scope.leases.removeValue(forKey: id),
              ticket.expires > ProcessInfo.processInfo.systemUptime,
              let record = scope.records[ticket.target], let numbers = object["bytes"] as? [NSNumber],
              !numbers.isEmpty, numbers.count <= 16384,
              numbers.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue == Double($0.intValue) && (0...255).contains($0.intValue) }) else {
          throw MacNativeBackgroundFailure.unsupportedSecret
        }
        var bytes = Data(numbers.map { $0.uint8Value })
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        // The authenticated AppHost has already awaited beforeDispatch. The
        // system adapter performs another just-in-place check before its setter.
        switch scope.controller.write(bytes, lease: lease, access: access(record), beforeDispatch: live) {
        case .setterAccepted: response = ["format": 1, "state": "sent"]
        case .refused(let error): response = Self.refused(error)
        case .unknown: response = ["format": 1, "state": "unknown", "errorCode": "fill_unknown"]
        }
      default: throw MacNativeBackgroundFailure.unsupportedTarget
      }
    } catch { response = Self.refused((error as? MacNativeBackgroundFailure) ?? .targetUnavailable) }
    return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
  }
  private static func refused(_ failure: MacNativeBackgroundFailure) -> [String: Any] {
    let code: String
    switch failure {
    case .permissionRequired: code = "access_denied"
    case .unauthorized: code = "scope_not_approved"
    case .sessionUnavailable, .wrongThread: code = "session_unavailable"
    case .unsupportedApplication, .unsupportedTarget, .ambiguousTarget: code = "unsupported_target"
    case .targetChanged: code = "destination_changed"
    case .unsupportedSecret: code = "unsupported_secret"
    case .busy: code = "busy"
    default: code = "target_unavailable"
    }
    return ["format": 1, "state": "refused", "errorCode": code]
  }
}
