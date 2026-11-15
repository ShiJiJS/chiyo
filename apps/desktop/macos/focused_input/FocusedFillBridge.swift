import FlutterMacOS
import Foundation
import AppKit

/// Owner bridge; constructing it only registers the private method channel.
/// The connection ID is local cancellation bookkeeping;
/// actual peer authentication and native target leases remain inside XPC.
final class MacFocusedFillBridge {
  private let channel: FlutterMethodChannel
  private var active: (id: String, client: MacFocusOwnerClient?)?
  private var closed = false
  private var permissionClient: MacFocusPermissionClient?
  private var permissionOpening = false

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "agent_info_manage/focused_fill", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, reply in self?.handle(call, reply) }
  }

  deinit { channel.setMethodCallHandler(nil); active?.client?.close() }

  func close() {
    closed = true
    permissionClient?.close()
    permissionClient = nil
    active?.client?.close()
    active = nil
  }

  private func handle(_ call: FlutterMethodCall, _ reply: @escaping FlutterResult) {
    guard !closed else {
      if call.method == "permissionDetails" || call.method == "requestNativePermissionDetails" {
        reply(Self.ownerDetails(.unavailable))
      } else if call.method == "openAccessibilitySettings" || call.method == "revealApplication" {
        reply(false)
      } else { refused("session_unavailable", reply) }
      return
    }
    if call.method == "openAccessibilitySettings" || call.method == "revealApplication" {
      guard noArguments(call) else { reply(false); return }
      DispatchQueue.main.async {
        if call.method == "openAccessibilitySettings" {
          let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
          reply(NSWorkspace.shared.open(url))
        } else {
          let application = Bundle.main.bundleURL
          guard application.pathExtension == "app" else { reply(false); return }
          NSWorkspace.shared.activateFileViewerSelecting([application])
          reply(true)
        }
      }
      return
    }
    if call.method == "permissionDetails" || call.method == "requestNativePermissionDetails" {
      guard noArguments(call) else { reply(Self.ownerDetails(.unavailable)); return }
      guard !permissionOpening, permissionClient == nil, active == nil else {
        reply(Self.ownerDetails(.busy)); return
      }
      permissionOpening = true
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        let client = try? MacFocusPermissionClient()
        DispatchQueue.main.async {
          guard let self else { client?.close(); reply(Self.ownerDetails(.unavailable)); return }
          self.permissionOpening = false
          guard !self.closed, let client else { reply(Self.ownerDetails(.unavailable)); return }
          self.permissionClient = client
          let completed: (MacFocusPermissionDetails) -> Void = { [weak self] details in
            DispatchQueue.main.async {
              self?.permissionClient = nil
              reply(Self.ownerDetails(self?.closed == false ? details : .unavailable))
            }
          }
          if call.method == "requestNativePermissionDetails" { client.requestNativePermissionDetails(reply: completed) }
          else { client.permissionDetails(reply: completed) }
        }
      }
      return
    }
    if call.method == "permissions" || call.method == "requestPermission" {
      guard call.arguments == nil || (call.arguments as? [String: Any])?.isEmpty == true else {
        reply(MacFocusPermissionStatus.unavailable.wire); return
      }
      guard !permissionOpening, permissionClient == nil, active == nil else {
        reply(MacFocusPermissionStatus(state: "unavailable", errorCode: "busy").wire); return
      }
      permissionOpening = true
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        let client = try? MacFocusPermissionClient()
        DispatchQueue.main.async {
          guard let self else { client?.close(); reply(MacFocusPermissionStatus.unavailable.wire); return }
          self.permissionOpening = false
          guard !self.closed, let client else {
            reply(MacFocusPermissionStatus.unavailable.wire); return
          }
          self.permissionClient = client
          client.query(prompt: call.method == "requestPermission") { [weak self] status in
            DispatchQueue.main.async { self?.permissionClient = nil; reply(status.wire) }
          }
        }
      }
      return
    }
    guard let arguments = call.arguments as? [String: Any],
          let id = arguments["connection"] as? String, id.utf8.count == 32,
          id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
      refused("input_rejected", reply)
      return
    }
    let keys = Set(arguments.keys)
    switch call.method {
    case "close":
      guard keys == ["connection"] else { refused("input_rejected", reply); return }
      if active?.id == id { active?.client?.close(); active = nil }
      reply(nil)
    case "inspect", "prepare":
      guard active == nil, !permissionOpening, permissionClient == nil else { refused("busy", reply); return }
      let application: MacFocusApplication?
      if call.method == "prepare" {
        guard keys == ["connection", "application"],
              let raw = arguments["application"] as? [String: String], Set(raw.keys) == ["executable", "sha256"],
              let path = raw["executable"], let sha = raw["sha256"],
              let parsed = try? MacFocusApplication(executable: path, sha256: sha) else {
          refused("application_changed", reply); return
        }
        application = parsed
      } else {
        guard keys == ["connection"] else { refused("input_rejected", reply); return }
        application = nil
      }
      open(id, application, reply)
    case "send":
      guard keys == ["connection", "bytes"], let data = arguments["bytes"] as? FlutterStandardTypedData,
            data.data.count > 0, data.data.count <= 32, data.data.count % 2 == 0 else {
        refused("unsupported_secret", reply); return
      }
      guard let current = active, current.id == id, let client = current.client else { refused("target_unavailable", reply); return }
      client.send(data.data) { [weak self] result in
        DispatchQueue.main.async {
          if result.state != "sent", self?.active?.id == id {
            self?.active?.client?.close()
            self?.active = nil
          }
          // A close/cancel racing a submitted batch must not erase that fact.
          reply(result.wire)
        }
      }
    default: reply(FlutterMethodNotImplemented)
    }
  }

  private func open(_ id: String, _ application: MacFocusApplication?, _ reply: @escaping FlutterResult) {
    active = (id, nil)
    // Sealed-package validation may touch many files. Keep it off the owner UI
    // thread. A local close can cancel this slot while validation is in flight;
    // completion cannot resurrect it or send a late prepare/input request.
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let client = try? MacFocusOwnerClient()
      DispatchQueue.main.async {
        guard let self, self.active?.id == id else {
          client?.close()
          reply(MacFocusReply(state: "refused", errorCode: "session_unavailable").wire)
          return
        }
        guard let client else { self.active = nil; self.refused("session_unavailable", reply); return }
        self.active = (id, client)
        let completed: (MacFocusReply) -> Void = { [weak self, weak client] result in
          DispatchQueue.main.async {
            guard let self, self.active?.id == id else {
              client?.close()
              reply(MacFocusReply(state: "refused", errorCode: "session_unavailable").wire)
              return
            }
            if result.state != "prepared" { client?.close(); self.active = nil }
            var wire = result.wire
            wire.removeValue(forKey: "lease")
            reply(wire)
          }
        }
        if let application { client.prepare(application, reply: completed) }
        else { client.inspect(reply: completed) }
      }
    }
  }

  private func refused(_ code: String, _ reply: FlutterResult) {
    reply(MacFocusReply(state: "refused", errorCode: code).wire)
  }

  private func noArguments(_ call: FlutterMethodCall) -> Bool {
    call.arguments == nil || (call.arguments as? [String: Any])?.isEmpty == true
  }

  private static func ownerDetails(_ details: MacFocusPermissionDetails) -> [String: Any] {
    var result = details.wire
    let bundle = Bundle.main
    result["applicationName"] = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
      ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
      ?? bundle.bundleURL.deletingPathExtension().lastPathComponent
    result["applicationPath"] = bundle.bundleURL.path
    return result
  }
}
