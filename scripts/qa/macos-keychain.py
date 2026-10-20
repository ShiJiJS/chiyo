#!/usr/bin/env python3
"""Isolated real Keychain probe; no production account or database is opened."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]


def main():
    if sys.platform != "darwin" or len(sys.argv) != 2:
        raise SystemExit("Usage on macOS: macos-keychain.py NEW_OUTPUT_DIRECTORY")
    output = Path(sys.argv[1]).resolve()
    output.relative_to(ROOT / "build" / "macos-adaptation")
    output.mkdir(parents=True, exist_ok=False)
    service = "org.shijijs.agent-info-manage.qa." + str(uuid.uuid4())
    identity = "org.shijijs.agent-info-manage.qa.keychain"
    results = {"service": service, "scope": "native signed sandbox probe, not Flutter UI", "steps": []}

    def run(command, *, required=True, name):
        started = time.monotonic()
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        except subprocess.TimeoutExpired as error:
            result = subprocess.CompletedProcess(
                command, 124,
                (error.stdout or b"").decode("utf-8", errors="replace"),
                "Timed out after 30 seconds; subprocess terminated by runner.")
        record = {"name": name, "exit": result.returncode,
                  "elapsedSeconds": round(time.monotonic() - started, 3),
                  "stdout": result.stdout, "stderr": result.stderr}
        results["steps"].append(record)
        (output / "result.json").write_text(json.dumps(results, indent=2) + "\n")
        print(name, result.returncode, flush=True)
        if required and result.returncode:
            raise RuntimeError(f"{name} failed; see isolated result.json")
        return result

    executables = {}
    for variant in ["A", "B"]:
        app = output / f"Keychain-{variant}.app"
        contents = app / "Contents"
        binary = contents / "MacOS" / "keychain-probe"
        binary.parent.mkdir(parents=True)
        with (contents / "Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": identity,
                          "CFBundleExecutable": binary.name,
                          "CFBundleName": "Mac Keychain QA",
                          "CFBundlePackageType": "APPL",
                          "CFBundleVersion": "1" if variant == "A" else "2"}, stream)
        run(["xcrun", "swiftc", "-parse-as-library",
             *([] if variant == "A" else ["-D", "SECOND_BUILD"]),
             str(ROOT / "apps/desktop/macos/Runner/DatabaseKeyStore.swift"),
             str(ROOT / "scripts/qa/macos-keychain-probe.swift"), "-o", str(binary)],
            name=f"compile-{variant}")
        run(["codesign", "--force", "--sign", "-", "--entitlements",
             str(ROOT / "apps/desktop/macos/Runner/Release.entitlements"), str(app)],
            name=f"sign-{variant}")
        run(["codesign", "--verify", "--deep", "--strict", str(app)],
            name=f"verify-{variant}")
        executables[variant] = str(binary)
        results[f"binary-{variant}-sha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()

    try:
        for step in ["missing", "create", "read", "duplicate"]:
            run([executables["A"], service, step], name=f"A-{step}")
        # A separate ad-hoc-signed build with the same bundle identity is an
        # observation, not permission to broaden the Keychain access policy.
        upgraded = run([executables["B"], service, "read"], required=False,
                       name="B-read-after-upgrade")
        if upgraded.returncode not in (0, 73):
            raise RuntimeError("Changed signing identity must return a result, not hang.")
        results["upgradeAccess"] = "preserved" if upgraded.returncode == 0 else "denied"
        run([executables["A"], service, "read"], name="A-read-after-upgrade-probe")
        run([executables["A"], service, "delete"], name="A-delete-before-malformed")
        run([executables["A"], service, "malformed"], name="A-reject-malformed")
    finally:
        run([executables["A"], service, "delete"], name="cleanup-owned-test-item")
        run([executables["A"], service, "missing"], name="verify-owned-test-item-absent")
    results["complete"] = True
    (output / "result.json").write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
