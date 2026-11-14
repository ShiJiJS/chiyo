import FlutterMacOS
import Foundation

/// Runner-side private channel only; all AX operations remain in the helper.
final class MacNativeBackgroundBridge {
  private let channel: FlutterMethodChannel
  private var clients: [String: MacNativeBackgroundOwnerClient] = [:]
  private var opening: [String: UUID] = [:]
  private var closed = false
  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "agent_info_manage/native_background_fill", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, reply in self?.handle(call, reply) }
  }
  deinit { channel.setMethodCallHandler(nil); for client in clients.values { client.close() } }
  func close() { closed = true; for client in clients.values { client.close() }; clients.removeAll() }
  private func handle(_ call: FlutterMethodCall, _ reply: @escaping FlutterResult) {
    guard !closed, let envelope = call.arguments as? [String: Any], Set(envelope.keys) == ["owner", "request"],
          let owner = envelope["owner"] as? String, owner.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil,
          var object = envelope["request"] as? [String: Any], object["format"] as? Int == 1,
          object["command"] as? String == call.method else { refused(reply); return }
    if call.method == "dispose" {
      guard Set(object.keys) == ["format", "command"] else { refused(reply); return }
      for key in opening.keys.filter({ $0.hasPrefix(owner + ":") }) { opening.removeValue(forKey: key) }
      for key in clients.keys.filter({ $0.hasPrefix(owner + ":") }) { clients.removeValue(forKey: key)?.close() }
      reply(["format": 1, "state": "disposed"])
      return
    }
    guard ["discover", "prepare", "setValue", "close", "release"].contains(call.method),
          let scope = object["scope"] as? String,
          scope.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { refused(reply); return }
    let key = owner + ":" + scope
    if let bytes = object["bytes"] as? FlutterStandardTypedData { object["bytes"] = [UInt8](bytes.data) }
    guard let data = try? JSONSerialization.data(withJSONObject: object), data.count <= 131072 else { refused(reply); return }
    let sending = call.method == "setValue"
    let dispatch: (MacNativeBackgroundOwnerClient) -> Void = { [weak self] client in
      client.request(data, sending: sending) { result in
        DispatchQueue.main.async {
          if !client.available, self?.clients[key] === client { self?.clients.removeValue(forKey: key) }
          reply((try? JSONSerialization.jsonObject(with: result)) ?? ["format": 1, "state": sending ? "unknown" : "refused", "errorCode": sending ? "fill_unknown" : "session_unavailable"])
        }
      }
    }
    if let client = clients[key] { dispatch(client); return }
    guard call.method == "discover", clients.count + opening.count < 128, opening[key] == nil else { refused(reply); return }
    let openingID = UUID()
    opening[key] = openingID
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let client = try? MacNativeBackgroundOwnerClient()
      DispatchQueue.main.async {
        guard let self else { client?.close(); reply(["format": 1, "state": "refused", "errorCode": "session_unavailable"]); return }
        guard self.opening[key] == openingID else { client?.close(); self.refused(reply); return }
        self.opening.removeValue(forKey: key)
        guard !self.closed, let client else { client?.close(); self.refused(reply); return }
        self.clients[key] = client; dispatch(client)
      }
    }
  }
  private func refused(_ reply: FlutterResult) { reply(["format": 1, "state": "refused", "errorCode": "session_unavailable"]) }
}
