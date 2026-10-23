import Darwin
import Foundation

/// Private embedded XPC executable only. There is no CLI mode, arbitrary owner
/// path, environment override or switch that admits an unverified desktop.
@main
enum MacFocusServiceMain {
  static func main() {
    guard CommandLine.arguments.count == 1 else { exit(EX_USAGE) }
    do {
      let service = try MacFocusPrivateService()
      // NSXPCListener.service().resume() enters the launchd-managed run loop.
      // Keep its weak listener delegate alive for that entire lifetime.
      withExtendedLifetime(service) { service.resume() }
    } catch {
      // No raw Security/framework errors, paths, targets or input on stdout or
      // stderr. The owner observes a terminal unavailable connection.
    }
    // An unsuccessful bootstrap or unexpectedly returning listener is terminal.
    // Do not fall back to a public listener or a standalone input process.
    exit(EX_CONFIG)
  }
}
