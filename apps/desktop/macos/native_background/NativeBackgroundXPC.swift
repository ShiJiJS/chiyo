import Foundation

@objc(MacNativeBackgroundPrivateV1)
protocol MacNativeBackgroundPrivateProtocol: MacFocusPrivateProtocol {
  func nativeRequest(_ request: Data, reply: @escaping (Data) -> Void)
}

/// The existing sealed-package/signed-peer factory is reused. No public service,
/// peer PID parameter, launcher argument or environment override is introduced.
final class MacNativeBackgroundOwnerClient {
  private let connection: NSXPCConnection
  private let queue = DispatchQueue(label: "org.shijijs.native-background-client")
  private var ended = false
  private var pending: (UUID, Bool, (Data) -> Void)?
  init() throws {
    connection = try MacFocusPrivateConnection.open()
    connection.remoteObjectInterface = NSXPCInterface(with: MacNativeBackgroundPrivateProtocol.self)
    connection.invalidationHandler = { [weak self] in self?.close() }
    connection.interruptionHandler = { [weak self] in self?.close() }
    connection.resume()
  }
  deinit { connection.invalidate() }
  var available: Bool { queue.sync { !ended } }
  func close() {
    queue.async { [self] in
      guard !ended else { return }
      ended = true; connection.invalidate()
      if let current = pending { pending = nil; current.2(Self.fallback(current.1)) }
    }
  }
  func request(_ data: Data, sending: Bool, reply: @escaping (Data) -> Void) {
    queue.async { [self] in
      guard !ended else { reply(Self.fallback(sending)); return }
      guard pending == nil else { reply(Self.encoded("refused", "busy")); return }
      let id = UUID(); pending = (id, sending, reply)
      guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in self?.finish(id, nil) }) as? MacNativeBackgroundPrivateProtocol else {
        complete(id, nil); return
      }
      queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.complete(id, nil) }
      proxy.nativeRequest(data) { [weak self] in self?.finish(id, $0) }
    }
  }
  private func finish(_ id: UUID, _ data: Data?) { queue.async { [weak self] in self?.complete(id, data) } }
  private func complete(_ id: UUID, _ data: Data?) {
    guard let current = pending, current.0 == id else { return }
    pending = nil
    guard let data, data.count <= 1024 * 1024,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["format"] as? Int == 1 else {
      ended = true; connection.invalidate(); current.2(Self.fallback(current.1)); return
    }
    current.2(data)
  }
  private static func fallback(_ sending: Bool) -> Data { encoded(sending ? "unknown" : "refused", sending ? "fill_unknown" : "session_unavailable") }
  private static func encoded(_ state: String, _ error: String) -> Data {
    (try? JSONSerialization.data(withJSONObject: ["format": 1, "state": state, "errorCode": error])) ?? Data()
  }
}
