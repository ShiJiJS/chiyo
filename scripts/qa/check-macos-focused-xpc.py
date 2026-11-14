#!/usr/bin/env python3
"""Exercise the real private helper from a sandboxed synthetic owner.

Does not open a library, request TCC or launch the installed app. By default
only permission status is queried. --synthetic-target temporarily activates an
AppKit fixture and sends a fixed synthetic Unicode value in two batches.
Builds/runs only temporary project-local signed App/XPC fixtures, removes them,
and retains a small permission/connection report under build/macos-adaptation.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import plistlib
import platform
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("focused_bundle", ROOT / "scripts/bundle-macos-focused-helper.py")
BUNDLE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUNDLE)
SOURCE = ROOT / "apps/desktop/macos/focused_input"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--synthetic-target", action="store_true", help="Focus a temporary AppKit secure field and send a fixed synthetic value")
    parser.add_argument("--plain-target", action="store_true", help="Verify an ordinary text field is refused without input")
    parser.add_argument("--native-status", action="store_true", help="Query frozen native wire from the signed sandboxed owner; no input")
    parser.add_argument("--native-archive-target", action="store_true", help="Fill only the pre-opened NativeBackgroundProofSigned.zip synthetic prompt")
    parser.add_argument("--dispatch-gate", action="store_true", help="Native archive QA only: wait for an independent observer's gate")
    args = parser.parse_args()
    if args.plain_target:
        args.synthetic_target = True
    if args.native_status and args.synthetic_target:
        parser.error("native status never sends input")
    if args.native_archive_target and (args.native_status or args.synthetic_target):
        parser.error("native archive target is a separate synthetic check")
    output = ROOT / ("build/macos-adaptation/focused-target-check" if args.synthetic_target else "build/macos-adaptation/focused-xpc-check")
    if args.plain_target:
        output = ROOT / "build/macos-adaptation/focused-plain-target-check"
    output.mkdir(parents=True, exist_ok=True)
    if args.native_status:
        output = ROOT / "build/macos-adaptation/native-background-xpc-check"
        output.mkdir(parents=True, exist_ok=True)
    if args.native_archive_target:
        output = ROOT / "build/macos-adaptation/native-background-archive-check"
        output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="run-", dir=output) as temporary:
        work = Path(temporary)
        app = work / "info_desktop.app"
        contents = app / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Resources").mkdir()
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.example.infoDesktop", "CFBundleExecutable": "info_desktop",
            "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "LSMinimumSystemVersion": "14.0"}))
        fixture = work / "Probe.swift"
        fixture.write_text('''import Foundation
import Darwin
@main enum Probe {
  static func main() {
    do {
      let client = try MacFocusPermissionClient()
      client.query(prompt: false) { status in
        let data = try! JSONSerialization.data(withJSONObject: status.wire, options: [.sortedKeys])
        print(String(data: data, encoding: .utf8)!)
        fflush(stdout)
        exit(status.state == "unavailable" ? 2 : 0)
      }
      withExtendedLifetime(client) { RunLoop.main.run() }
    } catch { print("{\\"connection\\":\\"initialization_failed\\"}"); exit(3) }
  }
}
''')
        if args.synthetic_target:
            fixture.write_text('''import Foundation
import Darwin
@main enum Probe {
  static func finish(_ state: String, _ code: String? = nil) {
    var result = ["state": state]
    if let code { result["errorCode"] = code }
    print(String(data: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    fflush(stdout)
    exit(state == "sent" ? 0 : 2)
  }
  static func main() {
    do {
      let client = try MacFocusOwnerClient()
      client.inspect { found in
        guard found.state == "ready", let application = found.application else { finish(found.state, found.errorCode); return }
        client.prepare(application) { prepared in
          guard prepared.state == "prepared" else { finish(prepared.state, prepared.errorCode); return }
          let units = Array("Synthetic-pass-1234567890-示例😊".utf16)
          let first = Data(units.prefix(16).flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })
          let last = Data(units.dropFirst(16).flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })
          client.send(first) { sent in
            guard sent.state == "sent" else { finish(sent.state, sent.errorCode); return }
            client.send(last) { final in finish(final.state, final.errorCode) }
          }
        }
      }
      withExtendedLifetime(client) { RunLoop.main.run() }
    } catch { finish("initialization_failed") }
  }
}
''')
        if args.native_status:
            fixture.write_text('''import Foundation
import Darwin
@main enum Probe {
  static func main() {
    do {
      let client = try MacNativeBackgroundOwnerClient()
      let request = try JSONSerialization.data(withJSONObject: ["format": 1, "command": "discover",
        "scope": String(repeating: "a", count: 64), "appId": "unregistered.synthetic.application"])
      client.request(request, sending: false) { data in
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { exit(4) }
        print(String(data: data, encoding: .utf8)!); fflush(stdout)
        let valid = (result["state"] as? String == "ready" && (result["targets"] as? [Any])?.isEmpty == true) ||
          (result["state"] as? String == "refused" && result["errorCode"] as? String == "access_denied")
        exit(valid ? 0 : 2)
      }
      withExtendedLifetime(client) { RunLoop.main.run() }
    } catch { print("initialization_failed"); exit(3) }
  }
}
''')
        if args.native_archive_target:
            fixture.write_text('''import Foundation
import Darwin
@main enum Probe {
  static func main() {
    do {
      let client = try MacNativeBackgroundOwnerClient()
      let scope = String(repeating: "a", count: 64)
      func send(_ command: String, _ payload: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        let object = ["format": 1, "command": command, "scope": scope].merging(payload) { _, b in b }
        client.request(try! JSONSerialization.data(withJSONObject: object), sending: command == "setValue") { data in
          guard let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { exit(4) }
          completion(reply)
        }
      }
      send("discover", ["appId": "com.apple.archiveutility"]) { found in
        guard let targets = found["targets"] as? [[String: Any]], targets.count == 1,
              let target = targets.first, let id = target["targetId"] as? String,
              (target["fieldLabel"] as? String)?.contains("NativeBackgroundProofSigned.zip") == true else {
          print("synthetic_target_unavailable"); fflush(stdout); exit(2)
        }
        send("prepare", ["targetId": id, "expected": target]) { prepared in
          guard let lease = prepared["leaseId"] as? String else { print("prepare_refused"); fflush(stdout); exit(2) }
          // Synthetic owner's explicit approval. The real AppHost awaits its
          // durable beforeDispatch callback; no caller PID/profile is accepted.
          send("setValue", ["leaseId": lease, "bytes": Array("Synthetic-Zip-42!".utf8)]) { result in
            print(String(data: try! JSONSerialization.data(withJSONObject: result), encoding: .utf8)!); fflush(stdout)
            exit(result["state"] as? String == "sent" ? 0 : 2)
          }
        }
      }
      withExtendedLifetime(client) { RunLoop.main.run() }
    } catch { print("initialization_failed"); exit(3) }
  }
}
''')
        command = ["xcrun", "swiftc", "-target", "arm64-apple-macos14.0", "-swift-version", "5", "-warnings-as-errors",
                   "-module-cache-path", str(work / "modules")]
        subprocess.run(command + [str(SOURCE / name) for name in ["FocusedFillContract.swift", "FocusProcessIdentity.swift",
                       "FocusedFillXPC.swift", "FocusedFillOwnerClient.swift"]]
                       + [str(SOURCE.parent / "native_background/NativeBackgroundXPC.swift")]
                       + [str(fixture), "-o", str(contents / "MacOS/info_desktop")], check=True)
        worker_source = work / "worker.c"
        worker_source.write_text("int main(void) { return 0; }\n")
        subprocess.run(["xcrun", "clang", "-target", "arm64-apple-macos14.0", str(worker_source), "-o", str(contents / "MacOS/info-runtime-worker")], check=True)
        for path, entitlement in [(contents / "MacOS/info-runtime-worker", "Worker.entitlements"), (app, "Release.entitlements")]:
            BUNDLE.command(["codesign", "--force", "--sign", "-", "--timestamp=none", "--entitlements",
                            str(ROOT / "apps/desktop/macos/Runner" / entitlement), str(path)])
        BUNDLE.assemble(app)
        BUNDLE.command(["codesign", "--verify", "--deep", "--strict", str(app)])
        if args.native_archive_target and args.dispatch_gate:
            ready, go = output / "dispatch-ready", output / "dispatch-go"
            go.unlink(missing_ok=True)
            (output / "dispatch-completed").unlink(missing_ok=True)
            ready.write_text("ready")
            deadline = time.monotonic() + 30
            while not go.exists() and time.monotonic() < deadline:
                time.sleep(.02)
            if not go.exists():
                raise RuntimeError("Observer did not open the synthetic dispatch gate; no input sent")
        target_process = None
        if args.synthetic_target:
            target_app = work / "SyntheticSecureTarget.app"
            target_contents = target_app / "Contents"
            (target_contents / "MacOS").mkdir(parents=True)
            (target_contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "org.shijijs.SyntheticSecureTarget", "CFBundleExecutable": "Target",
                "CFBundleName": "Synthetic Secure Field", "CFBundlePackageType": "APPL", "CFBundleVersion": "1"}))
            target_source = work / "Target.swift"
            target_source.write_text('''import AppKit
import Darwin
@main enum Target {
  static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 420, height: 120),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Synthetic focused-fill check"
    let field = NSSecureTextField(frame: NSRect(x: 20, y: 40, width: 380, height: 24))
    window.contentView!.addSubview(field)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(field)
    app.activate(ignoringOtherApps: true)
    let deadline = ProcessInfo.processInfo.systemUptime + 12
    let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
      let matched = field.stringValue == "Synthetic-pass-1234567890-示例😊"
      if matched || ProcessInfo.processInfo.systemUptime >= deadline {
        print(matched ? "synthetic-value-matched" : "synthetic-value-mismatch")
        fflush(stdout)
        exit(matched ? 0 : 4)
      }
    }
    withExtendedLifetime((window, field, timer)) { app.run() }
  }
}
''')
            if args.plain_target:
                target_source.write_text(target_source.read_text().replace("NSSecureTextField", "NSTextField")
                    .replace("systemUptime + 12", "systemUptime + 3")
                    .replace('let matched = field.stringValue == "Synthetic-pass-1234567890-示例😊"',
                             'let matched = ProcessInfo.processInfo.systemUptime >= deadline && field.stringValue.isEmpty')
                    .replace("synthetic-value-matched", "plain-field-unchanged"))
            subprocess.run(command + [str(target_source), "-parse-as-library", "-o", str(target_contents / "MacOS/Target")], check=True)
            BUNDLE.command(["codesign", "--force", "--sign", "-", "--timestamp=none", str(target_app)])
            target_process = subprocess.Popen([str(target_contents / "MacOS/Target")], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            time.sleep(1)
        try:
            result = subprocess.run([str(contents / "MacOS/info_desktop")], capture_output=True, text=True, timeout=15)
        except BaseException:
            if target_process is not None:
                target_process.kill()
                target_process.communicate()
            raise
        if args.native_archive_target and args.dispatch_gate:
            (output / "dispatch-completed").write_text(str(result.returncode))
        report = {"format": 1, "kind": "synthetic-sandboxed-owner-private-xpc", "exit": result.returncode,
                  "macOS": platform.mac_ver()[0],
                  "sourceCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                  "sourceInputs": {str(path.relative_to(ROOT)): BUNDLE.BUILDER.digest(path)
                                   for path in sorted(list(SOURCE.glob("*.swift")) + list((SOURCE.parent / "native_background").glob("*.swift")))},
                  "ownerExecutableSHA256": BUNDLE.BUILDER.digest(contents / "MacOS/info_desktop"),
                  "helperExecutableSHA256": BUNDLE.BUILDER.digest(app / BUNDLE.HELPER / "Contents/MacOS/AgentInfoFocusedFill"),
                  "ownerSandbox": BUNDLE.entitlements(app).get("com.apple.security.app-sandbox"),
                  "helperEntitlements": BUNDLE.entitlements(app / BUNDLE.HELPER),
                  "permissionPrompted": False, "inputAttempted": args.synthetic_target or args.native_archive_target, "temporaryAppRemoved": True,
                  "stdout": result.stdout.strip(), "stderr": result.stderr.strip()}
        if target_process is not None:
            try:
                target_out, target_err = target_process.communicate(timeout=15)
            except subprocess.TimeoutExpired:
                target_process.kill()
                target_out, target_err = target_process.communicate()
            report["syntheticTargetExit"] = target_process.returncode
            report["syntheticTargetResult"] = target_out.strip()
            report["syntheticTargetError"] = target_err.strip()
            report["exit"] = report["exit"] or target_process.returncode
            if args.plain_target:
                expected = {"state": "refused", "errorCode": "unsupported_target"}
                report["ordinaryTargetRefused"] = result.returncode == 2 and json.loads(result.stdout) == expected and target_process.returncode == 0
                report["exit"] = 0 if report["ordinaryTargetRefused"] else 1
    (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    raise SystemExit(report["exit"])


if __name__ == "__main__":
    main()
