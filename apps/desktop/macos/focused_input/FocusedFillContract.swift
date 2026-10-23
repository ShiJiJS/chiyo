import Foundation

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
