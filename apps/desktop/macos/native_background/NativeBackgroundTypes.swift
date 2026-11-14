import Foundation

/// Helper-local types, deliberately not a public/Core/CLI wire contract.
/// An authenticated owner constructs access only after checking the durable
/// grant, device/session, application identity and operation. A selector/PID is
/// never accepted as authority. No new RPC is exposed by this module.
struct MacNativeBackgroundAccess {
  let scopeID: UUID
  let application: MacFocusApplication
  let isAuthorized: () -> Bool
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
  func sameTarget(_ a: MacNativeBackgroundCandidate, _ b: MacNativeBackgroundCandidate) -> Bool
  func recheck(_ candidate: MacNativeBackgroundCandidate) throws
  func write(_ secret: String, to candidate: MacNativeBackgroundCandidate,
             authorized: () -> Bool) -> MacNativeBackgroundWriteResult
}

extension MacNativeBackgroundEnvironment {
  func sameTarget(_ a: MacNativeBackgroundCandidate, _ b: MacNativeBackgroundCandidate) -> Bool {
    a.reference === b.reference
  }
}
