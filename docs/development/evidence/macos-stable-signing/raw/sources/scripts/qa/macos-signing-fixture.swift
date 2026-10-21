import Foundation
import Security

@main struct SignerFixture {
  struct Failure: Error { let step: String; let status: Int32 }
  static func main() {
    func check(_ status: OSStatus, _ step: String) throws {
      if status != errSecSuccess { throw Failure(step: step, status: status) }
    }
    do {
      let data = FileHandle.standardInput.readDataToEndOfFile()
      guard let input = try JSONSerialization.jsonObject(with: data) as? [String: String],
            let root = input["root"], let owner = input["owner"],
            owner.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil,
            URL(fileURLWithPath: root).resolvingSymlinksInPath().path == root,
            root.hasPrefix(FileManager.default.currentDirectoryPath + "/build/macos-adaptation/"),
            URL(fileURLWithPath: root).lastPathComponent.hasPrefix("private-"),
            try String(contentsOfFile: root + "/.qa-owner", encoding: .utf8) == owner else {
        throw Failure(step: "invalid_owned_fixture", status: -1)
      }
      let path = root + "/signer.keychain"
      guard URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path,
            URL(fileURLWithPath: path + "-db").resolvingSymlinksInPath().path == path + "-db" else {
        throw Failure(step: "foreign_keychain_link", status: -1)
      }
      if input["action"] == "delete" {
        var keychain: SecKeychain?
        try check(SecKeychainOpen(path, &keychain), "open_owned_keychain")
        guard let keychain else { throw Failure(step: "missing_owned_keychain", status: -1) }
        try check(SecKeychainDelete(keychain), "delete_owned_keychain")
        print("{\"deletedOwnedKeychain\":true}")
        return
      }
      guard input["action"] == "prepare", let password = input["password"],
            !FileManager.default.fileExists(atPath: path),
            !FileManager.default.fileExists(atPath: path + "-db") else {
        throw Failure(step: "existing_or_invalid_fixture", status: -1)
      }
      var keychain: SecKeychain?
      try check(password.withCString { SecKeychainCreate(path, UInt32(password.utf8.count), $0, false, nil, &keychain) }, "create_private_signing_keychain")
      guard let keychain else { throw Failure(step: "no_private_signing_keychain", status: -1) }
      try check(SecKeychainSetUserInteractionAllowed(false), "disable_fixture_process_ui")
      var trusted: SecTrustedApplication?
      try check(SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &trusted), "codesign_trusted_application")
      var access: SecAccess?
      try check(SecAccessCreate("Isolated synthetic code signing" as CFString, [trusted!] as CFArray, &access), "codesign_only_acl")
      let pass = password as CFString
      for label in ["A", "Other"] {
        let bundle = try Data(contentsOf: URL(fileURLWithPath: root + "/" + label + ".p12"))
        var format = SecExternalFormat.formatPKCS12
        var type = SecExternalItemType.itemTypeAggregate
        var params = SecItemImportExportKeyParameters()
        params.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
        params.passphrase = Unmanaged.passUnretained(pass)
        params.accessRef = Unmanaged.passUnretained(access!)
        var items: CFArray?
        try check(SecItemImport(bundle as CFData, nil, &format, &type, [], &params, keychain, &items), "import_synthetic_identity_" + label)
      }
      // This new file keychain contains only the two synthetic signing keys.
      // Keep the explicit codesign application ACL; no allow-any-app flag.
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
      process.arguments = ["set-key-partition-list", "-S", "apple:", "-s", "-t", "private", "-k", password, path]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run(); process.waitUntilExit()
      guard process.terminationStatus == 0 else { throw Failure(step: "private_signing_key_partition", status: process.terminationStatus) }
      print("{\"createdPrivateSigningKeychain\":true,\"identities\":2,\"trustedSigningTool\":\"/usr/bin/codesign\",\"anyApplicationACL\":false,\"systemTrustChanged\":false}")
    } catch let failure as Failure {
      print("{\"failedStage\":\"\(failure.step)\",\"status\":\(failure.status)}")
      exit(1)
    } catch {
      print("{\"failedStage\":\"fixture_io\"}")
      exit(1)
    }
  }
}
