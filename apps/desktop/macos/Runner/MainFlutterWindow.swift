import Cocoa
import FlutterMacOS
import Security

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Local, owner-process-only bridge; never exposed by the Agent HTTP server.
    let keyChannel = FlutterMethodChannel(name: "agent_info_manage/database_key", binaryMessenger: flutterViewController.engine.binaryMessenger)
    keyChannel.setMethodCallHandler { call, result in
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "org.shijijs.agent-info-manage.database",
        kSecAttrAccount as String: "local-database-v1",
        kSecUseDataProtectionKeychain as String: false,
        kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
      ]
      if call.method == "read" {
        var readQuery = query
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var output: CFTypeRef?
        let status = SecItemCopyMatching(readQuery as CFDictionary, &output)
        if status == errSecItemNotFound { result(nil); return }
        guard status == errSecSuccess, let data = output as? Data, data.count == 32 else {
          result(FlutterError(code: "key_unavailable", message: "System key unavailable", details: nil)); return
        }
        result(FlutterStandardTypedData(bytes: data))
      } else if call.method == "create" {
        guard let data = call.arguments as? FlutterStandardTypedData, data.data.count == 32 else {
          result(FlutterError(code: "invalid_key", message: "Invalid key", details: nil)); return
        }
        var writeQuery = query
        writeQuery[kSecValueData as String] = data.data
        // SecItemAdd refuses duplicates; key failure never replaces an existing key.
        let status = SecItemAdd(writeQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
          result(FlutterError(code: "key_creation_failed", message: "System key creation failed", details: nil)); return
        }
        result(nil)
      } else { result(FlutterMethodNotImplemented) }
    }

    super.awakeFromNib()
  }
}
