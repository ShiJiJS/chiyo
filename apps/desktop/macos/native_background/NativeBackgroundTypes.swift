import Foundation

/// Helper-local types, deliberately not a public/Core/CLI wire contract.
/// An authenticated owner constructs access only after checking the durable
/// grant, device/session, application version and operation. A selector/PID is
/// never accepted as authority. No new RPC is exposed by this module.
struct MacNativeBackgroundAccess {
  let scopeID: UUID
  let application: MacFocusApplication
  let isAuthorized: () -> Bool
}

/// Maintainer-controlled compatibility evidence, separate from user approval.
/// Empty by default. Exact executable versions and stable identifiers must have
/// passed native AppKit tests. AXSecureTextField alone cannot prove AppKit class
/// provenance; arbitrary callers must not be allowed to register profiles.
struct MacNativeBackgroundProfile {
  let application: MacFocusApplication
  let bundleIdentifier: String
  let codeRequirement: String
  let windowIdentifiers: Set<String>
  let fieldIdentifiers: Set<String>
  var fieldLabels: [String: String] = [:]
  var operatingSystemBuild: String? = nil
  var contextIdentifiers: Set<String> = []
  var requiredSecureFieldIdentifiers: Set<String>? = nil
  var contextPatterns: [String: String] = [:]
}

enum MacNativeBackgroundFailure: String, Error {
  case permissionRequired, sessionUnavailable, unsupportedApplication
  case targetUnavailable, targetChanged, ambiguousTarget, unsupportedTarget
  case expired, consumed, unauthorized, unsupportedSecret, wrongThread, busy
}

enum MacNativeBackgroundWriteResult: Equatable {
  /// AX setter returned success. No value readback, event/submit/login claim.
  case setterAccepted
  case refused(MacNativeBackgroundFailure)
  /// A setter was invoked but acceptance is uncertain. Never replay.
  case unknown
}

struct MacNativeBackgroundDescriptor {
  let candidateID: UUID
  let windowIdentifier: String
  let windowTitle: String
  let fieldIdentifier: String
  let fieldLabel: String
}

final class MacNativeBackgroundCandidate {
  let descriptor: MacNativeBackgroundDescriptor
  let reference: AnyObject
  init(descriptor: MacNativeBackgroundDescriptor, reference: AnyObject) {
    self.descriptor = descriptor
    self.reference = reference
  }
}

protocol MacNativeBackgroundEnvironment: AnyObject {
  func discover(_ application: MacFocusApplication) throws -> [MacNativeBackgroundCandidate]
  func recheck(_ candidate: MacNativeBackgroundCandidate) throws
  func write(_ secret: String, to candidate: MacNativeBackgroundCandidate,
             authorized: () -> Bool) -> MacNativeBackgroundWriteResult
}
