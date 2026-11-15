import Darwin
import Foundation
import Security

/// A private embedded service only. No Mach service, LaunchAgent, arbitrary
/// target PID, event kind or executable can be supplied by an Agent.
@objc(MacFocusedFillPrivateV1)
protocol MacFocusPrivateProtocol {
  func permissions(reply: @escaping (Data) -> Void)
  func requestPermission(reply: @escaping (Data) -> Void)
  func permissionDetails(reply: @escaping (Data) -> Void)
  func requestNativePermissionDetails(reply: @escaping (Data) -> Void)
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
