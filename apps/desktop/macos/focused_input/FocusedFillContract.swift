import Foundation
import CoreFoundation

struct MacFocusApplication: Equatable {
  let executable: String
  let sha256: String

  init(executable: String, sha256: String) throws {
    guard executable.hasPrefix("/"), !executable.hasPrefix("//"),
          executable.count > 1, !executable.hasSuffix("/"), executable.utf8.count <= 4096,
          !executable.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
          sha256.utf8.count == 64,
          sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
      throw MacFocusFailure("application_changed")
    }
    self.executable = executable
    self.sha256 = sha256
  }

  var wire: [String: String] { ["executable": executable, "sha256": sha256] }
}

struct MacFocusFailure: Error {
  let code: String
  init(_ code: String) { self.code = code }
}

/// Only the controller/environment retain a native reference. It is never part
/// of a discovery reply, grant, history, backup or Agent-facing message.
final class MacFocusTarget {
  let application: MacFocusApplication
  let reference: AnyObject
  init(application: MacFocusApplication, reference: AnyObject) {
    self.application = application
    self.reference = reference
  }
}

enum MacFocusPosting {
  case submitted
  case refused(String)
  case unknown
}

protocol MacFocusEnvironment: AnyObject {
  func capture() throws -> MacFocusTarget
  func recheck(_ target: MacFocusTarget) throws
  func post(_ units: [UInt16], to target: MacFocusTarget) throws -> MacFocusPosting
}

protocol MacFocusSerialGate: AnyObject {
  func acquire() throws
  func release()
}

struct MacFocusReply {
  let state: String
  var errorCode: String? = nil
  var application: MacFocusApplication? = nil
  var lease: String? = nil

  var wire: [String: Any] {
    var value: [String: Any] = ["format": 1, "state": state]
    if let errorCode { value["errorCode"] = errorCode }
    if let application { value["application"] = application.wire }
    if let lease { value["lease"] = lease }
    return value
  }
}

/// Helper-owned OS permission status, independent of target discovery.
struct MacFocusPermissionStatus {
  let state: String
  var errorCode: String? = nil
  var wire: [String: Any] {
    var value: [String: Any] = ["format": 1, "state": state, "platform": "macos"]
    if let errorCode { value["errorCode"] = errorCode }
    return value
  }
  static let unavailable = MacFocusPermissionStatus(state: "unavailable", errorCode: "session_unavailable")
  static func decode(_ data: Data) -> MacFocusPermissionStatus? {
    guard data.count <= 1024,
          let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          value["format"] as? Int == 1, value["platform"] as? String == "macos",
          let state = value["state"] as? String else { return nil }
    if state == "ready", Set(value.keys) == ["format", "state", "platform"] {
      return MacFocusPermissionStatus(state: state)
    }
    guard Set(value.keys) == ["format", "state", "platform", "errorCode"],
          let code = value["errorCode"] as? String,
          (state == "permission_required" && code == "permission_required") ||
          (state == "unavailable" && ["session_unavailable", "busy"].contains(code)) else { return nil }
    return MacFocusPermissionStatus(state: state, errorCode: code)
  }
}

/// Helper-owned preflights are separate facts; neither boolean implies that a
/// target exists or that any credential may be delivered.
struct MacFocusPermissionDetails {
  let accessibilityTrusted: Bool?
  let postEventsTrusted: Bool?
  let errorCode: String?
  var state: String { errorCode == nil ? "checked" : "unavailable" }

  init(accessibilityTrusted: Bool, postEventsTrusted: Bool) {
    self.accessibilityTrusted = accessibilityTrusted
    self.postEventsTrusted = postEventsTrusted
    errorCode = nil
  }
  private init(errorCode: String) {
    accessibilityTrusted = nil
    postEventsTrusted = nil
    self.errorCode = errorCode
  }
  static let unavailable = MacFocusPermissionDetails(errorCode: "session_unavailable")
  static let busy = MacFocusPermissionDetails(errorCode: "busy")

  var wire: [String: Any] {
    var result: [String: Any] = ["format": 2, "platform": "macos", "state": state]
    if let errorCode { result["errorCode"] = errorCode }
    else {
      result["accessibilityTrusted"] = accessibilityTrusted!
      result["postEventsTrusted"] = postEventsTrusted!
    }
    return result
  }

  static func decode(_ data: Data) -> MacFocusPermissionDetails? {
    guard data.count <= 1024,
          let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          value["format"] as? Int == 2, value["platform"] as? String == "macos" else { return nil }
    if value["state"] as? String == "checked" {
      guard Set(value.keys) == ["format", "platform", "state", "accessibilityTrusted", "postEventsTrusted"],
            let ax = boolean(value["accessibilityTrusted"]), let events = boolean(value["postEventsTrusted"]) else { return nil }
      return MacFocusPermissionDetails(accessibilityTrusted: ax, postEventsTrusted: events)
    }
    guard value["state"] as? String == "unavailable",
          Set(value.keys) == ["format", "platform", "state", "errorCode"],
          let code = value["errorCode"] as? String, ["busy", "session_unavailable"].contains(code) else { return nil }
    return MacFocusPermissionDetails(errorCode: code)
  }

  private static func boolean(_ value: Any?) -> Bool? {
    guard let value, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
    return value as? Bool
  }
}

/// The OS boundary offers a request for AX only. Event posting is a separate
/// preflight, never a side effect of requesting native AX setter access.
struct MacFocusPermissionProbe {
  let accessibility: () -> Bool
  let postEvents: () -> Bool
  let requestAccessibility: () -> Void

  func read(requestNative: Bool) -> MacFocusPermissionDetails {
    if requestNative { requestAccessibility() }
    let ax = accessibility()
    let events = postEvents()
    return MacFocusPermissionDetails(accessibilityTrusted: ax, postEventsTrusted: events)
  }
}
