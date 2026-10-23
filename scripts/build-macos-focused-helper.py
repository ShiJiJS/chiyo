#!/usr/bin/env python3
"""Build a private focused-fill XPC candidate into a NEW project-local directory.

Build/sign/inspect only. Never execute or embed the helper, launch an App,
register a service, request TCC, modify a keychain or change any installed app.
The native supported-session policy stays closed; this is not capability enablement.
"""

import argparse
import hashlib
import json
from pathlib import Path
import platform
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OUTPUT_ROOT = ROOT / "build/macos-adaptation"
SOURCE = ROOT / "apps/desktop/macos/focused_input"
SERVICE = "org.shijijs.AgentInfoFocusedFill"
EXECUTABLE = "AgentInfoFocusedFill"
SOURCE_NAMES = ["FocusedFillContract.swift", "FocusProcessIdentity.swift", "FocusedFillController.swift",
                "FocusSerialGate.swift", "SystemFocusEnvironment.swift", "FocusedFillXPC.swift",
                "FocusedFillXPCService.swift", "ServiceMain.swift"]


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(65536), b""):
            value.update(block)
    return value.hexdigest()


def output_path(requested):
    # Resolve parent aliases before checking containment, including a final
    # dangling symlink. Never accept an existing output, even an empty directory.
    if requested.exists() or requested.is_symlink():
        raise ValueError("Output already exists; choose a NEW directory")
    if OUTPUT_ROOT.resolve() != OUTPUT_ROOT:
        raise ValueError("Candidate output root must not be redirected")
    resolved = requested.resolve()
    relative = resolved.relative_to(OUTPUT_ROOT)
    if not relative.parts or resolved.suffix.lower() in {".app", ".xpc", ".dsym"}:
        raise ValueError("Output must be a new candidate directory under build/macos-adaptation")
    return resolved


def service_info():
    value = plistlib.loads((SOURCE / "ServiceInfo.plist").read_bytes())
    if (value.get("CFBundleIdentifier") != SERVICE or value.get("CFBundleExecutable") != EXECUTABLE
            or value.get("CFBundlePackageType") != "XPC!" or value.get("LSMinimumSystemVersion") != "14.0"
            or value.get("XPCService") != {"ServiceType": "Application", "JoinExistingSession": True,
                                           "RunLoopType": "NSRunLoop"}):
        raise ValueError("Unexpected private XPC package contract")
    return value


def minimum_versions(text):
    command, versions = "", []
    for line in text.splitlines():
        words = line.split()
        if len(words) != 2:
            continue
        if words[0] == "cmd":
            command = words[1]
        if (command == "LC_BUILD_VERSION" and words[0] == "minos") or (
                command == "LC_VERSION_MIN_MACOSX" and words[0] == "version"):
            versions.append(words[1])
    return versions


def build(requested):
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ValueError("Build the candidate on ARM64 macOS with Xcode")
    output = output_path(requested)
    info = service_info()
    inputs = [SOURCE / name for name in SOURCE_NAMES + ["ServiceInfo.plist"]] + [Path(__file__).resolve()]
    source_hashes = {str(path.relative_to(ROOT)): digest(path) for path in inputs}
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    tracked = subprocess.run(["git", "ls-files", "--error-unmatch", *source_hashes], cwd=ROOT,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    changed = subprocess.run(["git", "diff", "HEAD", "--quiet", "--", *source_hashes], cwd=ROOT).returncode != 0
    output.mkdir(parents=True, exist_ok=False)
    report = {"format": 1, "kind": "macos-focused-fill-xpc-candidate", "complete": False,
              "sourceCommit": commit, "sourceInputsDirty": changed or not tracked,
              "sourceInputs": source_hashes, "capabilityEnabled": False, "supportedSessions": [],
              "helperExecuted": False, "embeddedInApp": False, "phases": []}
    logs = output / "logs"
    logs.mkdir()

    def run(name, command):
        with (logs / (name + ".txt")).open("wb") as log:
            result = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=log, timeout=60)
            log.write(result.stdout)
        report["phases"].append({"name": name, "exit": result.returncode})
        if result.returncode:
            raise RuntimeError(f"{name} failed; see {logs / (name + '.txt')}")
        return result.stdout.decode()

    try:
        bundle = output / (SERVICE + ".xpc")
        contents = bundle / "Contents"
        program = contents / "MacOS" / EXECUTABLE
        program.parent.mkdir(parents=True)
        # No entitlements, copied framework, arbitrary resource, external entry
        # point, network operation or signed personal identity is accepted.
        (contents / "Info.plist").write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=False))
        with tempfile.TemporaryDirectory(prefix=".compile-", dir=output) as work:
            run("compile", ["xcrun", "swiftc", "-O", "-target", "arm64-apple-macos14.0",
                            "-swift-version", "5", "-warnings-as-errors", "-module-name", EXECUTABLE,
                            "-module-cache-path", str(Path(work) / "modules"),
                            *[str(SOURCE / name) for name in SOURCE_NAMES], "-o", str(program)])
        run("sign", ["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(bundle)])
        run("signature-check", ["/usr/bin/codesign", "--verify", "--strict", "--verbose=2", str(bundle)])
        architectures = run("architecture", ["/usr/bin/lipo", "-archs", str(program)]).split()
        minimums = minimum_versions(run("load-commands", ["/usr/bin/otool", "-l", str(program)]))
        links = run("dependencies", ["/usr/bin/otool", "-L", str(program)])
        dependencies = [line.strip().split(" (", 1)[0] for line in links.splitlines()[1:]]
        if architectures != ["arm64"] or minimums != ["14.0"]:
            raise RuntimeError("Unexpected candidate architecture/deployment target")
        if not dependencies or any(not path.startswith(("/usr/lib/", "/System/Library/")) for path in dependencies):
            raise RuntimeError("Unexpected non-system dependency")
        encoded = run("entitlements", ["/usr/bin/codesign", "-d", "--entitlements", ":-", str(bundle)])
        entitlements = plistlib.loads(encoded.encode()) if encoded.strip() else {}
        if entitlements:
            raise RuntimeError("Candidate must not acquire unexpected entitlements")
        source_after = {str(path.relative_to(ROOT)): digest(path) for path in inputs}
        if source_after != source_hashes:
            raise RuntimeError("Candidate source changed during compilation")
        report.update({"complete": True, "bundle": bundle.name, "architecture": "arm64",
                       "binaryMinimumMacOS": "14.0", "testedBuildHost": platform.mac_ver()[0],
                       "signing": "local ad-hoc development; not notarized", "declaredEntitlements": entitlements,
                       "dependencies": dependencies, "temporaryCompilerCacheRemoved": True,
                       "files": [{"path": str(path.relative_to(bundle)), "bytes": path.stat().st_size,
                                  "sha256": digest(path)} for path in [program, contents / "Info.plist", contents / "_CodeSignature/CodeResources"]]})
        return report
    finally:
        (output / "manifest.json").write_text(json.dumps(report, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="NEW directory under build/macos-adaptation")
    args = parser.parse_args()
    try:
        result = build(args.output)
    except (ValueError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, str(error) + "\n")
    print(json.dumps({"complete": result["complete"], "bundle": result["bundle"],
                      "helperExecuted": False, "capabilityEnabled": False}, indent=2))


if __name__ == "__main__":
    main()
