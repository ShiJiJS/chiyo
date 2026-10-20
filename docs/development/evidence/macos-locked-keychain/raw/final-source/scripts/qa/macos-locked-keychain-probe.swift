import Foundation
import Security

// Only the isolated native source copy refers to this explicit keychain.
// Never pass nil to a lock/unlock/delete operation (nil means the default).
var qaKeychain: SecKeychain?

@main
struct LockedKeychainProbe {
  struct Failure: Error { let step: String; let status: OSStatus? }
  static func main() {
    var facts: [String: Any] = ["complete": false]
    var root: URL?
    var beforeList: CFArray?
    var beforeDefault: SecKeychain?
    var failed = false
    var interactionBefore: DarwinBoolean = false
    func check(_ status: OSStatus, _ step: String) throws {
      guard status == errSecSuccess else { throw Failure(step: step, status: status) }
    }
    func require(_ value: Bool, _ step: String) throws {
      guard value else { throw Failure(step: step, status: nil) }
    }
    func unlocked(_ keychain: SecKeychain) throws -> Bool {
      var state: SecKeychainStatus = 0
      try check(SecKeychainGetStatus(keychain, &state), "keychain_status")
      return (state & SecKeychainStatus(kSecUnlockStateStatus)) != 0
    }
    do {
      try check(SecKeychainGetUserInteractionAllowed(&interactionBefore), "interaction_before")
      try check(SecKeychainCopySearchList(&beforeList), "search_list_before")
      try check(SecKeychainCopyDefault(&beforeDefault), "default_before")
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aim-locked-keychain-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      root = directory
      var bytes = [UInt8](repeating: 0, count: 32)
      try check(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes), "random_password")
      let password = bytes.map { String(format: "%02x", $0) }.joined()
      // Password exists only in this process. No argv, environment, file or log.
      let path = directory.appendingPathComponent("fixture.keychain").path
      let created = password.withCString {
        SecKeychainCreate(path, UInt32(password.utf8.count), $0, false, nil, &qaKeychain)
      }
      try check(created, "create_private_keychain")
      guard let keychain = qaKeychain else { throw Failure(step: "missing_keychain", status: nil) }
      var currentDefault: SecKeychain?
      try check(SecKeychainCopyDefault(&currentDefault), "default_after_create")
      try require(CFEqual(beforeDefault, currentDefault), "default_changed")
      facts["defaultUnchangedAfterCreate"] = true
      try require(try unlocked(keychain), "new_keychain_locked")
      let store = NativeDatabaseKeyStore(service: "org.shijijs.agent-info-manage.qa." + UUID().uuidString)
      try require(try store.read() == nil, "unexpected_existing_item")
      var sample = Data(count: 32)
      let randomStatus = sample.withUnsafeMutableBytes { pointer in
        SecRandomCopyBytes(kSecRandomDefault, 32, pointer.baseAddress!)
      }
      try check(randomStatus, "random_key")
      try store.create(sample)
      try require(try store.read() == sample, "initial_key_mismatch")
      facts["createdAndReadOriginalKey"] = true
      try check(SecKeychainLock(keychain), "lock_private_keychain")
      try require(try !unlocked(keychain), "lock_not_observed")
      facts["actualLockedStateObserved"] = true
      let started = Date()
      var errors: [OSStatus] = []
      for _ in 0..<2 {
        do {
          _ = try store.read()
          throw Failure(step: "locked_read_allowed", status: nil)
        } catch let error as DatabaseKeyFailure {
          try require(error.code == "key_unavailable", "wrong_locked_read_error")
          errors.append(error.status ?? 0)
        }
        try require(try !unlocked(keychain), "read_unlocked_keychain")
      }
      facts["lockedReadStatuses"] = errors
      facts["twoLockedReadSeconds"] = Date().timeIntervalSince(started)
      do {
        try store.create(Data(repeating: 213, count: 32))
        throw Failure(step: "locked_duplicate_created", status: nil)
      } catch let error as DatabaseKeyFailure {
        facts["lockedDuplicateStatus"] = error.status ?? 0
      }
      let unlockStatus = password.withCString {
        SecKeychainUnlock(keychain, UInt32(password.utf8.count), $0, true)
      }
      try check(unlockStatus, "unlock_owned_keychain")
      try require(try unlocked(keychain), "unlock_not_observed")
      try require(try store.read() == sample, "original_key_changed")
      facts["unlockedOriginalKeyPreserved"] = true
      var interaction: DarwinBoolean = false
      try check(SecKeychainGetUserInteractionAllowed(&interaction), "interaction_after")
      try require(interaction.boolValue == interactionBefore.boolValue, "interaction_not_restored")
      facts["interactionRestored"] = true
    } catch let failure as Failure {
      failed = true
      facts["failure"] = failure.step
      facts["osStatus"] = failure.status ?? 0
    } catch let error as DatabaseKeyFailure {
      failed = true
      facts["failure"] = error.code
      facts["osStatus"] = error.status ?? 0
    } catch {
      failed = true
      facts["failure"] = String(describing: type(of: error))
    }
    if let keychain = qaKeychain {
      let status = SecKeychainDelete(keychain)
      facts["ownedKeychainDeleteStatus"] = status
      if status != errSecSuccess { failed = true }
    }
    var afterList: CFArray?
    var afterDefault: SecKeychain?
    let listStatus = SecKeychainCopySearchList(&afterList)
    let defaultStatus = SecKeychainCopyDefault(&afterDefault)
    let restored = listStatus == errSecSuccess && defaultStatus == errSecSuccess &&
        CFEqual(beforeList, afterList) && CFEqual(beforeDefault, afterDefault)
    facts["searchListAndDefaultRestored"] = restored
    if !restored { failed = true }
    if let directory = root {
      facts["remainingOwnedNamesAfterKeychainDelete"] = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
      if !failed {
        do {
          try FileManager.default.removeItem(at: directory)
          facts["ownedRootRemoved"] = !FileManager.default.fileExists(atPath: directory.path)
        } catch { failed = true }
      } else {
        facts["retainedOwnedRoot"] = directory.path
      }
    }
    facts["complete"] = !failed
    let data = try! JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    exit(failed ? 1 : 0)
  }
}
