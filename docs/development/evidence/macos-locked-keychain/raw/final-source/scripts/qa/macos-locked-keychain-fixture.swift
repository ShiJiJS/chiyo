// QA COPY ONLY. Appended to MainFlutterWindow in --locked-keychain mode.
// Explicit queries target this owned file keychain. No default/search-list
// setter, LockAll, production service, password argument or permission UI.
private var qaPrivateKeychain: SecKeychain?
private var qaPrivatePassword: String?

func ownedPrivateKeychain() throws -> SecKeychain {
  guard let keychain = qaPrivateKeychain else {
    throw DatabaseKeyFailure(code: "qa_private_keychain_missing", status: nil)
  }
  return keychain
}

private func qaKeychainContext() throws -> [String: String] {
  var list: CFArray?
  var defaultKeychain: SecKeychain?
  guard SecKeychainCopySearchList(&list) == errSecSuccess,
        SecKeychainCopyDefault(&defaultKeychain) == errSecSuccess,
        let entries = list as? [SecKeychain], let selected = defaultKeychain else {
    throw DatabaseKeyFailure(code: "qa_context_unavailable", status: nil)
  }
  func path(_ keychain: SecKeychain) throws -> String {
    var size: UInt32 = 4096
    var buffer = [CChar](repeating: 0, count: Int(size))
    let status = SecKeychainGetPath(keychain, &size, &buffer)
    guard status == errSecSuccess else {
      throw DatabaseKeyFailure(code: "qa_context_path", status: status)
    }
    return String(cString: buffer)
  }
  func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  return ["default": digest(try path(selected)),
          "searchList": digest(try entries.map { try path($0) }.joined(separator: "\n"))]
}

private func privateKeychainFixture(_ method: String, _ arguments: Any?) throws -> [String: Any] {
  guard let data = arguments as? [String: String], let root = data["root"],
        let owner = ProcessInfo.processInfo.environment["INFO_MAC_KEYCHAIN_OWNER"],
        data["owner"] == owner,
        owner.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else {
    throw DatabaseKeyFailure(code: "qa_invalid_owner", status: nil)
  }
  let directory = URL(fileURLWithPath: root).resolvingSymlinksInPath()
  let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
  guard directory.path == root, directory.path.hasPrefix(temp.path + "/aim-mac-keychain-"),
        try String(contentsOf: directory.appendingPathComponent(".qa-owner"), encoding: .utf8) == owner else {
    throw DatabaseKeyFailure(code: "qa_foreign_root", status: nil)
  }
  let path = directory.appendingPathComponent("fixture.keychain").path
  let baseline = directory.appendingPathComponent("keychain-context.json")
  func check(_ status: OSStatus, _ code: String) throws {
    guard status == errSecSuccess else { throw DatabaseKeyFailure(code: code, status: status) }
  }
  func unlocked(_ keychain: SecKeychain) throws -> Bool {
    var status: SecKeychainStatus = 0
    try check(SecKeychainGetStatus(keychain, &status), "qa_private_status")
    return (status & SecKeychainStatus(kSecUnlockStateStatus)) != 0
  }
  switch method {
  case "qaPrivatePrepare":
    guard qaPrivateKeychain == nil,
          !FileManager.default.fileExists(atPath: path),
          !FileManager.default.fileExists(atPath: path + "-db"),
          !FileManager.default.fileExists(atPath: baseline.path) else {
      throw DatabaseKeyFailure(code: "qa_existing_fixture", status: nil)
    }
    let context = try qaKeychainContext()
    let json = try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys])
    guard FileManager.default.createFile(atPath: baseline.path, contents: json, attributes: [.posixPermissions: 0o600]) else {
      throw DatabaseKeyFailure(code: "qa_context_save", status: nil)
    }
    var bytes = [UInt8](repeating: 0, count: 32)
    try check(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes), "qa_random_password")
    let password = bytes.map { String(format: "%02x", $0) }.joined()
    let created = password.withCString {
      SecKeychainCreate(path, UInt32(password.utf8.count), $0, false, nil, &qaPrivateKeychain)
    }
    try check(created, "qa_private_create")
    qaPrivatePassword = password
    guard try qaKeychainContext()["default"] == context["default"] else {
      throw DatabaseKeyFailure(code: "qa_default_changed", status: nil)
    }
    return ["created": true, "unlocked": try unlocked(ownedPrivateKeychain()), "defaultUnchanged": true]
  case "qaPrivateLock":
    let keychain = try ownedPrivateKeychain()
    try check(SecKeychainLock(keychain), "qa_private_lock")
    return ["locked": try !unlocked(keychain)]
  case "qaPrivateUnlock":
    let keychain = try ownedPrivateKeychain()
    guard let password = qaPrivatePassword else {
      throw DatabaseKeyFailure(code: "qa_no_private_password", status: nil)
    }
    try check(password.withCString {
      SecKeychainUnlock(keychain, UInt32(password.utf8.count), $0, true)
    }, "qa_private_unlock")
    return ["unlocked": try unlocked(keychain)]
  case "qaPrivateStatus":
    return ["locked": try !unlocked(ownedPrivateKeychain())]
  case "qaPrivateCleanup":
    let exists = FileManager.default.fileExists(atPath: path) || FileManager.default.fileExists(atPath: path + "-db")
    var lockedBeforeDelete: Any = NSNull()
    if exists {
      var reference: SecKeychain?
      try check(SecKeychainOpen(path, &reference), "qa_private_open_cleanup")
      guard let keychain = reference else {
        throw DatabaseKeyFailure(code: "qa_private_missing_cleanup", status: nil)
      }
      lockedBeforeDelete = try !unlocked(keychain)
      try check(SecKeychainDelete(keychain), "qa_private_delete")
    }
    qaPrivateKeychain = nil
    qaPrivatePassword = nil
    let old = try JSONSerialization.jsonObject(with: Data(contentsOf: baseline)) as? [String: String]
    guard try old == qaKeychainContext(),
          !FileManager.default.fileExists(atPath: path),
          !FileManager.default.fileExists(atPath: path + "-db") else {
      throw DatabaseKeyFailure(code: "qa_cleanup_context_changed", status: nil)
    }
    return ["ownedKeychainDeleted": true, "searchListAndDefaultRestored": true,
            "keychainWasPresent": exists, "lockedBeforeDelete": lockedBeforeDelete]
  default:
    throw DatabaseKeyFailure(code: "qa_unknown_private_method", status: nil)
  }
}
