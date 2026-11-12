import AppKit
import Darwin
import Foundation

/// Synthetic owner only: no library, credential, permission prompt or clipboard write.
@main enum MacFocusedBrowserFixture {
  static var client: MacFocusOwnerClient!
  static var initialPasteboard = 0
  static let mode = CommandLine.arguments[1]
  static let browser = CommandLine.arguments[2]

  static func emit(_ event: String, _ reply: MacFocusReply) {
    var wire = reply.wire
    wire.removeValue(forKey: "lease")
    wire["event"] = event
    print(String(data: try! JSONSerialization.data(withJSONObject: wire, options: [.sortedKeys]), encoding: .utf8)!)
    fflush(stdout)
  }

  static func finish(_ reply: MacFocusReply) {
    emit("final", reply)
    let finalPasteboard = NSPasteboard.general.changeCount
    print("{\"clipboardChangeCountUnchanged\":\(finalPasteboard == initialPasteboard),\"clipboardBefore\":\(initialPasteboard),\"clipboardAfter\":\(finalPasteboard)}")
    fflush(stdout)
    client.close()
    exit(0)
  }

  static func awaitSignal(_ action: @escaping () -> Void) {
    DispatchQueue.global().async {
      guard readLine() == "continue" else { finish(MacFocusReply(state: "refused", errorCode: "session_unavailable")); return }
      action()
    }
  }

  static func send() {
    let units = Array("Synthetic-pass-1234567890-示例😊".utf16)
    let first = Data(units.prefix(16).flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })
    let rest = Data(units.dropFirst(16).flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })
    client.send(first) { result in
      emit("first", result)
      guard result.state == "sent" else { finish(result); return }
      if mode == "partial-focus-change" { awaitSignal { client.send(rest, reply: finish) } }
      else { client.send(rest, reply: finish) }
    }
  }

  static func main() {
    guard CommandLine.arguments.count == 3,
          ["fill", "inspect", "wrong-application", "focus-change", "partial-focus-change"].contains(mode),
          ["chrome", "safari"].contains(browser) else { exit(64) }
    initialPasteboard = NSPasteboard.general.changeCount
    do {
      client = try MacFocusOwnerClient()
      client.inspect { found in
        emit("inspect", found)
        guard found.state == "ready", let application = found.application else { finish(found); return }
        let expected = URL(fileURLWithPath: browser == "chrome"
          ? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
          : "/Applications/Safari.app/Contents/MacOS/Safari").resolvingSymlinksInPath().standardizedFileURL.path
        guard application.executable == expected else {
          finish(MacFocusReply(state: "refused", errorCode: "application_changed")); return
        }
        if mode == "inspect" { finish(found); return }
        let approved = mode == "wrong-application"
          ? try! MacFocusApplication(executable: application.executable, sha256: String(repeating: "0", count: 64))
          : application
        client.prepare(approved) { prepared in
          emit("prepare", prepared)
          guard prepared.state == "prepared" else { finish(prepared); return }
          if mode == "focus-change" { awaitSignal { send() } }
          else { send() }
        }
      }
      RunLoop.main.run()
    } catch { exit(3) }
  }
}
