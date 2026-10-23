#!/usr/bin/env python3
"""Compile candidate AX source; execute only headless controller/file-gate checks.

Never link/instantiate SystemMacFocusEnvironment in the executed binary. This
does not launch an App, request TCC, inspect a window, or send system input.
Temporary executables/lock fixtures are removed; keep only a small JSON report.
"""

import json
from pathlib import Path
import platform
import subprocess
import tempfile


def main():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("This developer check requires an ARM64 Mac with Xcode.")
    root = Path(__file__).resolve().parents[2]
    source = root / "apps/desktop/macos/focused_input"
    output = root / "build/macos-adaptation/issue51-native-controller"
    output.mkdir(parents=True, exist_ok=True)
    common = ["xcrun", "swiftc", "-target", "arm64-apple-macos14.0", "-swift-version", "5", "-warnings-as-errors"]
    module = [str(source / "FocusedFillController.swift"), str(source / "FocusSerialGate.swift")]
    framework = root / ".tools/flutter/bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64"
    subprocess.run(common + ["-typecheck"] + module + [str(source / "SystemFocusEnvironment.swift"),
                   str(source / "FocusedFillXPC.swift"), str(source / "FocusedFillOwnerClient.swift"),
                   str(source / "FocusedFillBridge.swift"), "-F", str(framework)],
                   check=True, cwd=root, timeout=60)
    with tempfile.TemporaryDirectory(prefix="headless-", dir=output) as temporary:
        executable = str(Path(temporary) / "controller-checks")
        subprocess.run(common + module + [str(source / "tests/ControllerChecks.swift"), "-o", executable],
                       check=True, cwd=root, timeout=60)
        completed = subprocess.run([executable, temporary], capture_output=True, text=True,
                                   check=True, cwd=root, timeout=20)
        report = json.loads(completed.stdout)
    report["systemAdapterTypechecked"] = True
    report["temporaryExecutableRemoved"] = True
    (output / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
