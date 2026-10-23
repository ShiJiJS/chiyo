#!/usr/bin/env python3
"""Compile candidate AX source; execute only headless controller/file-gate checks.

Never link/instantiate SystemMacFocusEnvironment in the executed binary. This
does not launch an App, request TCC, inspect a window, or send system input.
Temporary executables/lock fixtures are removed; keep a small report/diagnostic log.
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
    module = [str(source / "FocusedFillContract.swift"), str(source / "FocusedFillController.swift"),
              str(source / "FocusSerialGate.swift")]
    framework = root / ".tools/flutter/bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64"
    owner = ["FocusedFillContract.swift", "FocusProcessIdentity.swift", "FocusedFillXPC.swift",
             "FocusedFillOwnerClient.swift", "FocusedFillBridge.swift"]
    project = json.loads(subprocess.check_output(["/usr/bin/plutil", "-convert", "json", "-o", "-",
                         str(root / "apps/desktop/macos/Runner.xcodeproj/project.pbxproj")]))["objects"]
    runner = project["33CC10E92044A3C60003C045"]["files"]
    compiled = {project[project[reference]["fileRef"]]["path"] for reference in runner}
    if not set(owner).issubset(compiled) or set(compiled).intersection({
            "FocusedFillController.swift", "FocusSerialGate.swift", "SystemFocusEnvironment.swift",
            "FocusedFillXPCService.swift", "ServiceMain.swift"}):
        raise SystemExit("Runner must compile the owner bridge only, never the AX/input helper implementation")
    subprocess.run(common + ["-typecheck"] + module + [str(source / "SystemFocusEnvironment.swift"),
                   str(source / "FocusProcessIdentity.swift"), str(source / "FocusedFillXPC.swift"),
                   str(source / "FocusedFillXPCService.swift"), str(source / "ServiceMain.swift"),
                   str(source / "FocusedFillOwnerClient.swift"),
                   str(source / "FocusedFillBridge.swift"), "-F", str(framework)],
                   check=True, cwd=root, timeout=60)
    # Runner has existing deprecated Keychain/panel APIs. New focused-fill code
    # is checked with warnings-as-errors above; retain full Runner diagnostics.
    with (output / "runner-typecheck.txt").open("wb") as log:
        subprocess.run([arg for arg in common if arg != "-warnings-as-errors"] + ["-typecheck", "-F", str(framework)]
                       + [str(path) for path in sorted((root / "apps/desktop/macos/Runner").glob("*.swift"))]
                       + [str(root / "apps/desktop/macos/Flutter/GeneratedPluginRegistrant.swift")]
                       + [str(source / name) for name in owner], check=True, cwd=root, timeout=60,
                       stdout=log, stderr=subprocess.STDOUT)
    with tempfile.TemporaryDirectory(prefix="headless-", dir=output) as temporary:
        executable = str(Path(temporary) / "controller-checks")
        subprocess.run(common + module + [str(source / "tests/ControllerChecks.swift"), "-o", executable],
                       check=True, cwd=root, timeout=60)
        completed = subprocess.run([executable, temporary], capture_output=True, text=True,
                                   check=True, cwd=root, timeout=20)
        report = json.loads(completed.stdout)
    report["systemAdapterTypechecked"] = True
    report["runnerOwnerSourcesTypechecked"] = True
    report["systemAXAndServiceSourcesInRunner"] = False
    report["temporaryExecutableRemoved"] = True
    (output / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
