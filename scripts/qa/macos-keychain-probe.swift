import Foundation
import Security

// Compiled with the production key store. Only a generated QA service can be
// addressed; this tool cannot read, replace or delete the owner's database key.
@main
struct KeychainProbe {
  static func main() {
    let args = CommandLine.arguments
    let prefix = "org.shijijs.agent-info-manage.qa."
    guard args.count == 3, args[1].hasPrefix(prefix),
          UUID(uuidString: String(args[1].dropFirst(prefix.count))) != nil else {
      print("{\"status\":\"invalid_fixture\"}")
      exit(64)
    }
    let store = NativeDatabaseKeyStore(service: args[1])
    let sample = Data((0..<32).map { UInt8($0) })
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: args[1],
      kSecAttrAccount as String: NativeDatabaseKeyStore.account,
      kSecUseDataProtectionKeychain as String: false,
      kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
    ]
    var interactionBefore: DarwinBoolean = false
    guard SecKeychainGetUserInteractionAllowed(&interactionBefore) == errSecSuccess else {
      print("{\"status\":\"interaction_state_unavailable\"}")
      exit(70)
    }
    func checkInteractionRestored() {
      var after: DarwinBoolean = false
      guard SecKeychainGetUserInteractionAllowed(&after) == errSecSuccess,
            after.boolValue == interactionBefore.boolValue else {
        print("{\"status\":\"interaction_state_not_restored\"}")
        exit(70)
      }
    }
    do {
      switch args[2] {
      case "missing":
        guard try store.read() == nil else { throw ProbeFailure() }
      case "create":
        try store.create(sample)
        guard try store.read() == sample else { throw ProbeFailure() }
      case "read":
        guard try store.read() == sample else { throw ProbeFailure() }
      case "duplicate":
        do {
          try store.create(Data(repeating: 255, count: 32))
          throw ProbeFailure()
        } catch let error as DatabaseKeyFailure {
          guard error.status == errSecDuplicateItem else { throw error }
        }
        guard try store.read() == sample else { throw ProbeFailure() }
      case "malformed":
        var request = query
        request[kSecValueData as String] = Data(repeating: 1, count: 31)
        guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else {
          throw ProbeFailure()
        }
        do {
          _ = try store.read()
          throw ProbeFailure()
        } catch let error as DatabaseKeyFailure {
          guard error.code == "key_unavailable" else { throw error }
        }
      case "delete":
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
          throw DatabaseKeyFailure(code: "qa_cleanup_failed", status: status)
        }
      default:
        throw ProbeFailure()
      }
      checkInteractionRestored()
      #if SECOND_BUILD
        let build = "B"
      #else
        let build = "A"
      #endif
      print("{\"status\":\"passed\",\"build\":\"\(build)\",\"step\":\"\(args[2])\"}")
    } catch let error as DatabaseKeyFailure {
      checkInteractionRestored()
      let status = error.status.map(String.init) ?? "null"
      print("{\"status\":\"failed\",\"code\":\"\(error.code)\",\"osStatus\":\(status)}")
      exit(73)
    } catch {
      print("{\"status\":\"assertion_failed\"}")
      exit(70)
    }
  }

  struct ProbeFailure: Error {}
}
