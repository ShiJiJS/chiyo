// QA COPY ONLY: macos-flutter-keychain.py appends this to an isolated source
// copy. It is never included in the production Xcode target. @SERVICE@ is a
// fresh runner-owned UUID service; no caller-supplied service/account allowed.
private func mutateOwnedKeychainFixture(_ method: String) throws {
  var previous: DarwinBoolean = true
  guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
        SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
    throw DatabaseKeyFailure(code: "qa_interaction_failed", status: nil)
  }
  defer { SecKeychainSetUserInteractionAllowed(previous) }
  let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "@SERVICE@",
    kSecAttrAccount as String: NativeDatabaseKeyStore.account,
    kSecUseDataProtectionKeychain as String: false,
  ]
  let removed = SecItemDelete(query as CFDictionary)
  guard removed == errSecSuccess || removed == errSecItemNotFound else {
    throw DatabaseKeyFailure(code: "qa_delete_failed", status: removed)
  }
  if method != "qaDelete" {
    var insertion = query
    insertion[kSecValueData as String] = Data(repeating: 29, count: method == "qaMalformed" ? 31 : 32)
    let added = SecItemAdd(insertion as CFDictionary, nil)
    guard added == errSecSuccess else {
      throw DatabaseKeyFailure(code: "qa_insertion_failed", status: added)
    }
  }
}
