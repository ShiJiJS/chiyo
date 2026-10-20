import Foundation
import Security

struct DatabaseKeyFailure: Error {
  let code: String
  let status: OSStatus?
}

/// Owner-process-only storage. These identifiers are part of the existing
/// profile's identity; changing them requires an explicit migration.
final class NativeDatabaseKeyStore {
  static let service = "org.shijijs.agent-info-manage.database"
  static let account = "local-database-v1"
  private static let interactionLock = NSLock()
  private let service: String
  private let account: String

  init(service: String = NativeDatabaseKeyStore.service,
       account: String = NativeDatabaseKeyStore.account) {
    self.service = service
    self.account = account
  }

  private var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecUseDataProtectionKeychain as String: false
    ]
  }

  private func withInteraction<T>(_ allowed: Bool, _ action: () throws -> T) throws -> T {
    // This profile uses the legacy keychain. SecItem's authentication-UI flag
    // does not suppress legacy ACL prompts, which can block the Flutter thread.
    // Limit the process-wide legacy switch to the serialized native operation.
    Self.interactionLock.lock()
    defer { Self.interactionLock.unlock() }
    var previous: DarwinBoolean = true
    let readStatus = SecKeychainGetUserInteractionAllowed(&previous)
    guard readStatus == errSecSuccess else {
      throw DatabaseKeyFailure(code: "key_unavailable", status: readStatus)
    }
    let setStatus = SecKeychainSetUserInteractionAllowed(allowed)
    guard setStatus == errSecSuccess else {
      throw DatabaseKeyFailure(code: "key_unavailable", status: setStatus)
    }
    defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
    return try action()
  }

  func read(allowInteraction: Bool = false) throws -> Data? {
    try withInteraction(allowInteraction) {
      var request = query
      request[kSecMatchSearchList as String] = [try ownedPrivateKeychain()]
      request[kSecReturnData as String] = true
      request[kSecMatchLimit as String] = kSecMatchLimitOne
      var output: CFTypeRef?
      let status = SecItemCopyMatching(request as CFDictionary, &output)
      // Owner recovery must never create a replacement for a missing key.
      if status == errSecItemNotFound && !allowInteraction { return nil }
      guard status == errSecSuccess, let data = output as? Data, data.count == 32 else {
        throw DatabaseKeyFailure(code: "key_unavailable", status: status)
      }
      return data
    }
  }

  func create(_ data: Data) throws {
    guard data.count == 32 else {
      throw DatabaseKeyFailure(code: "invalid_key", status: nil)
    }
    try withInteraction(false) {
      var request = query
      request[kSecUseKeychain as String] = try ownedPrivateKeychain()
      request[kSecValueData as String] = data
      // Add refuses duplicates. Never replace a key after a read/open failure.
      let status = SecItemAdd(request as CFDictionary, nil)
      guard status == errSecSuccess else {
        throw DatabaseKeyFailure(code: "key_creation_failed", status: status)
      }
    }
  }
}
