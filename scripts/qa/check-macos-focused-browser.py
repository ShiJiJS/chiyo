#!/usr/bin/env python3
"""Test a real Chrome/Safari password field through the production private XPC helper.

Starts a loopback-only synthetic page and prints its URL. Open that URL in the
selected browser and keep the browser foreground until completion. The fixture
changes only its own DOM focus; it does not launch/activate browsers, request
permissions, sign in, submit a form, read real data or write the clipboard.
The temporary sandboxed owner and helper are removed; a value-free result.json
remains under ignored build/macos-adaptation/focused-browser-<browser>.
"""
import argparse
import importlib.util
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import platform
import plistlib
import select
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
QA = Path(__file__).resolve().parent
SOURCE = ROOT / "apps/desktop/macos/focused_input"
SPEC = importlib.util.spec_from_file_location("focused_bundle", ROOT / "scripts/bundle-macos-focused-helper.py")
BUNDLE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUNDLE)


def build_owner(work):
    app = work / "info_desktop.app"
    contents = app / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Resources").mkdir()
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.example.infoDesktop", "CFBundleExecutable": "info_desktop",
        "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "LSMinimumSystemVersion": "14.0"}))
    subprocess.run(["xcrun", "swiftc", "-target", "arm64-apple-macos14.0", "-swift-version", "5", "-warnings-as-errors",
                    "-module-cache-path", str(work / "modules"),
                    *[str(SOURCE / name) for name in ["FocusedFillContract.swift", "FocusProcessIdentity.swift",
                         "FocusedFillXPC.swift", "FocusedFillOwnerClient.swift"]],
                    str(QA / "macos-focused-browser-fixture.swift"), "-o", str(contents / "MacOS/info_desktop")], check=True)
    worker = work / "worker.c"
    worker.write_text("int main(void) { return 0; }\n")
    subprocess.run(["xcrun", "clang", "-target", "arm64-apple-macos14.0", str(worker), "-o",
                    str(contents / "MacOS/info-runtime-worker")], check=True)
    for path, entitlement in [(contents / "MacOS/info-runtime-worker", "Worker.entitlements"), (app, "Release.entitlements")]:
        BUNDLE.command(["codesign", "--force", "--sign", "-", "--timestamp=none", "--entitlements",
                        str(ROOT / "apps/desktop/macos/Runner" / entitlement), str(path)])
    BUNDLE.assemble(app)
    BUNDLE.command(["codesign", "--verify", "--deep", "--strict", str(app)])
    return app, contents / "MacOS/info_desktop"


class PageFixture:
    def __init__(self):
        self.condition = threading.Condition()
        self.report = None
        self.command = {"serial": 0, "focus": "password", "clear": True}
        fixture = self
        html = (QA / "macos-focused-browser-fixture.html").read_bytes()

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def send(self, value, content_type="application/json"):
                data = value if isinstance(value, bytes) else json.dumps(value).encode()
                self.send_response(200)
                self.send_header("Content-Type", content_type)
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                if self.path == "/":
                    self.send(html, "text/html; charset=utf-8")
                elif self.path == "/command":
                    with fixture.condition:
                        self.send(fixture.command)
                else:
                    self.send_response(404)
                    self.end_headers()

            def do_POST(self):
                if self.path != "/report" or int(self.headers.get("Content-Length", 0)) > 2048:
                    self.send_response(400)
                    self.end_headers()
                    return
                value = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                with fixture.condition:
                    fixture.report = value
                    fixture.condition.notify_all()
                self.send({"ok": True})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server.server_port}/"

    def wait(self, predicate, timeout=8):
        deadline = time.monotonic() + timeout
        with self.condition:
            while not (self.report is not None and predicate(self.report)):
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise RuntimeError("Synthetic page did not reach the required foreground focus/value state")
                self.condition.wait(min(remaining, 0.5))
            return dict(self.report)

    def focus(self, target="password", clear=True):
        with self.condition:
            self.command = {"serial": self.command["serial"] + 1, "focus": target, "clear": clear}
            serial = self.command["serial"]
        return self.wait(lambda r: r["serial"] == serial and r["focus"] == target and r["documentFocused"])

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


def wait_native_ready(owner, browser, timeout):
    """Read-only discovery may be repeated; no prepare or input is retried."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = subprocess.run([str(owner), "inspect", browser], capture_output=True, text=True, timeout=8)
        events = [json.loads(line) for line in result.stdout.splitlines()]
        if result.returncode == 0 and any(e.get("event") == "final" and e.get("state") == "ready" for e in events):
            return
        time.sleep(0.2)
    raise RuntimeError("Selected browser did not become the actual OS foreground secure target")


def run_case(owner, browser, mode, page):
    page.focus("plain" if mode == "plain-target" else "password")
    process = subprocess.Popen([str(owner), "inspect" if mode == "plain-target" else mode, browser],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    events = []
    try:
        deadline = time.monotonic() + 18
        while process.poll() is None or select.select([process.stdout], [], [], 0)[0]:
            if time.monotonic() >= deadline:
                raise RuntimeError("Native browser fixture timed out")
            if not select.select([process.stdout], [], [], 0.2)[0]:
                continue
            line = process.stdout.readline()
            if not line:
                break
            event = json.loads(line)
            events.append(event)
            if (mode == "focus-change" and event.get("event") == "prepare" and event.get("state") == "prepared") or (
                    mode == "partial-focus-change" and event.get("event") == "first" and event.get("state") == "sent"):
                if mode == "partial-focus-change":
                    # sent is only an OS submission receipt. Wait until the page
                    # receives the first batch before intentionally moving focus.
                    # Otherwise this test races already-queued native events,
                    # which cannot be atomically bound to an AX control.
                    page.wait(lambda r: r["passwordLength"] == 16 and r["plainEmpty"] and r["otherEmpty"])
                page.focus("other" if mode == "focus-change" else "plain", clear=False)
                process.stdin.write("continue\n")
                process.stdin.flush()
        process.wait(timeout=2)
        error = process.stderr.read().strip()
        if process.returncode or error:
            raise RuntimeError(f"Native browser fixture failed: {process.returncode}: {error}")
        final = next(e for e in events if e.get("event") == "final")
        expected = {
            "fill": ("sent", None), "wrong-application": ("refused", "application_changed"),
            "plain-target": ("refused", "unsupported_target"), "focus-change": ("refused", "focus_changed"),
            "partial-focus-change": ("partial", "focus_changed")}[mode]
        if (final.get("state"), final.get("errorCode")) != expected:
            raise RuntimeError(f"Unexpected native result for {mode}: {events}")
        if not any(e.get("clipboardChangeCountUnchanged") is True for e in events):
            raise RuntimeError("Pasteboard change count changed during native fixture")
        if mode == "fill":
            observed = page.wait(lambda r: r["passwordMatched"] and r["otherEmpty"] and r["plainEmpty"])
        elif mode == "partial-focus-change":
            observed = page.wait(lambda r: r["passwordLength"] == 16 and r["otherEmpty"] and r["plainEmpty"])
        else:
            observed = page.wait(lambda r: r["passwordEmpty"] and r["otherEmpty"] and r["plainEmpty"])
        return {"case": mode, "passed": True, "events": events, "page": observed}
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        for stream in [process.stdin, process.stdout, process.stderr]:
            stream.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--browser", choices=["chrome", "safari"], required=True)
    parser.add_argument("--page-timeout", type=float, default=180)
    args = parser.parse_args()
    output = ROOT / f"build/macos-adaptation/focused-browser-{args.browser}"
    output.mkdir(parents=True, exist_ok=True)
    browser_app = Path("/Applications/Google Chrome.app" if args.browser == "chrome" else "/Applications/Safari.app")
    browser_info = plistlib.loads((browser_app / "Contents/Info.plist").read_bytes())
    report = {"format": 1, "kind": "real-browser-synthetic-private-xpc", "browser": args.browser,
              "browserVersion": browser_info.get("CFBundleShortVersionString"),
              "browserBuild": browser_info.get("CFBundleVersion"), "macOS": platform.mac_ver()[0], "permissionPrompted": False, "cases": [], "complete": False,
              "sourceCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
              "fixtureInputs": {str(p.relative_to(ROOT)): BUNDLE.BUILDER.digest(p) for p in [Path(__file__).resolve(), QA / "macos-focused-browser-fixture.swift", QA / "macos-focused-browser-fixture.html"]},
              "sourceInputs": {str(p.relative_to(ROOT)): BUNDLE.BUILDER.digest(p) for p in sorted(SOURCE.glob("*.swift"))}}
    try:
        with tempfile.TemporaryDirectory(prefix="run-", dir=output) as temporary:
            app, owner = build_owner(Path(temporary))
            report["ownerExecutableSHA256"] = BUNDLE.BUILDER.digest(owner)
            report["helperExecutableSHA256"] = BUNDLE.BUILDER.digest(app / BUNDLE.HELPER / "Contents/MacOS/AgentInfoFocusedFill")
            report["ownerSandbox"] = BUNDLE.entitlements(app).get("com.apple.security.app-sandbox")
            report["helperEntitlements"] = BUNDLE.entitlements(app / BUNDLE.HELPER)
            page = PageFixture()
            try:
                print(json.dumps({"browser": args.browser, "openSyntheticPage": page.url,
                                  "instruction": "Keep this browser page in OS foreground until completion"}), flush=True)
                page.wait(lambda r: r["visible"] == "visible" and r["documentFocused"], timeout=args.page_timeout)
                wait_native_ready(owner, args.browser, args.page_timeout)
                for mode in ["fill", "wrong-application", "plain-target", "focus-change", "partial-focus-change"]:
                    case = run_case(owner, args.browser, mode, page)
                    report["cases"].append(case)
                    print(json.dumps({"case": mode, "passed": True}), flush=True)
                page.focus(clear=True)
                report["complete"] = True
            finally:
                page.close()
    except Exception as error:
        report["error"] = str(error)
    finally:
        report["temporaryAppRemoved"] = True
        (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    raise SystemExit(0 if report["complete"] else 1)


if __name__ == "__main__":
    main()
