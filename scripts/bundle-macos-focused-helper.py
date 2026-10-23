#!/usr/bin/env python3
"""Reconcile a disabled focused-fill candidate in an owned Mac BUILD product.

Default: remove only a previously recorded, byte-matching candidate. Opt in with
--with-focused-fill-candidate to build/embed/sign one. Never launch anything,
touch an installed app, request TCC, or activate the Dart/Agent capability.
"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
BUILD_PRODUCTS = ROOT / "apps/desktop/build/macos/Build/Products"
ADAPTATION = ROOT / "build/macos-adaptation"
SPEC = importlib.util.spec_from_file_location("focused_builder", ROOT / "scripts/build-macos-focused-helper.py")
BUILDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILDER)
HELPER = Path("Contents/XPCServices") / (BUILDER.SERVICE + ".xpc")
RECORD = Path("Contents/Resources/FocusedFill/manifest.json")
PAYLOAD_FILES = {"Contents/MacOS/AgentInfoFocusedFill", "Contents/Info.plist", "Contents/_CodeSignature/CodeResources"}


def app_path(requested, *, readonly=False):
    if requested.is_symlink():
        raise ValueError("Build app must not be a symlink")
    app = requested.resolve(strict=True)
    allowed = [BUILD_PRODUCTS, ROOT / "build" if readonly else ADAPTATION]
    allowed = [base for base in allowed if base.resolve() == base]
    if (app.name != "info_desktop.app" or
            not any(app.is_relative_to(base) for base in allowed)):
        raise ValueError("Expected an info_desktop.app under this checkout's build directories")
    for part in ["Contents", "Contents/MacOS", "Contents/Resources", "Contents/XPCServices", str(RECORD.parent)]:
        directory = app / part
        if directory.is_symlink() or (directory.exists() and not directory.is_dir()):
            raise ValueError("Build bundle contains a redirected or invalid directory")
    info = app / "Contents/Info.plist"
    program = app / "Contents/MacOS/info_desktop"
    if info.is_symlink() or program.is_symlink() or not program.is_file():
        raise ValueError("Build app identity is unavailable")
    values = plistlib.loads(info.read_bytes())
    if (not isinstance(values, dict) or values.get("CFBundleIdentifier") != "com.example.infoDesktop"
            or values.get("CFBundleExecutable") != "info_desktop"):
        raise ValueError("Unexpected build app identity")
    return app


def verify_helper(bundle, receipt):
    if (not isinstance(receipt, dict) or receipt.get("format") != 1 or receipt.get("kind") != "macos-focused-fill-xpc-candidate"
            or receipt.get("complete") is not True or receipt.get("capabilityEnabled") is not False
            or receipt.get("supportedSessions") != [] or receipt.get("declaredEntitlements") != {}
            or receipt.get("architecture") != "arm64" or receipt.get("binaryMinimumMacOS") != "14.0"
            or receipt.get("helperExecuted") is not False or receipt.get("embeddedInApp") is not False):
        raise ValueError("Unexpected candidate receipt")
    rows = receipt.get("files")
    if (not isinstance(rows, list) or len(rows) != 3 or
            any(not isinstance(row, dict) or not isinstance(row.get("path"), str) for row in rows) or
            {row.get("path") for row in rows} != PAYLOAD_FILES):
        raise ValueError("Unexpected candidate payload contract")
    if not bundle.is_dir() or bundle.is_symlink():
        raise ValueError("Candidate bundle is missing or redirected")
    paths = list(bundle.rglob("*"))
    if any(path.is_symlink() for path in paths) or {
            str(path.relative_to(bundle)) for path in paths if path.is_file()} != PAYLOAD_FILES:
        raise ValueError("Candidate contains unknown or redirected files")
    for row in rows:
        path = bundle / row["path"]
        if (path.stat().st_size != row.get("bytes") or path.stat().st_size > 16 * 1024 * 1024
                or BUILDER.digest(path) != row.get("sha256")):
            raise ValueError("Candidate bytes differ from its receipt")
    if not (bundle / "Contents/MacOS/AgentInfoFocusedFill").stat().st_mode & 0o100:
        raise ValueError("Candidate is not executable")
    if plistlib.loads((bundle / "Contents/Info.plist").read_bytes()) != BUILDER.service_info():
        raise ValueError("Candidate service metadata differs")


def inspect(requested):
    """Read-only check shared by the build wrapper and complete-package builder."""
    app = app_path(requested, readonly=True)
    record, helper = app / RECORD, app / HELPER
    if record.parent.exists() and {path.name for path in record.parent.iterdir()} - {record.name}:
        raise ValueError("FocusedFill resources contain unknown files")
    if not record.exists() and not record.is_symlink() and not helper.exists() and not helper.is_symlink():
        return None
    if record.is_symlink() or not record.is_file() or record.stat().st_size > 65536:
        raise ValueError("Unmanaged focused-fill helper in build output")
    value = json.loads(record.read_text())
    if (not isinstance(value, dict) or set(value) != {"format", "kind", "ownerBundleIdentifier", "capabilityEnabled", "helper"}
            or value["format"] != 1 or value["kind"] != "macos-focused-fill-embedded-candidate"
            or value["ownerBundleIdentifier"] != "com.example.infoDesktop" or value["capabilityEnabled"] is not False
            or not isinstance(value["helper"], dict)):
        raise ValueError("Unmanaged focused-fill build record")
    verify_helper(helper, value["helper"])
    return value


def command(arguments):
    result = subprocess.run(arguments, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    return result.stdout


def entitlements(path):
    encoded = command(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(path)])
    return plistlib.loads(encoded) if encoded.strip() else {}


def seal(app, parent, worker, worker_digest, worker_rights):
    command(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none",
             "--preserve-metadata=entitlements,requirements,flags,runtime", str(app)])
    command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    if entitlements(app) != parent or entitlements(worker) != worker_rights or BUILDER.digest(worker) != worker_digest:
        raise RuntimeError("App sealing changed owner/worker sandbox metadata or worker bytes")


def assemble(requested, *, enabled=False, build_helper=None):
    app = app_path(requested)
    previous = inspect(app)
    if not enabled and previous is None:
        return {"included": False, "modified": False, "capabilityEnabled": False}
    command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    signing = subprocess.run(["/usr/bin/codesign", "-dv", "--verbose=4", str(app)], check=True,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60).stderr.decode()
    if "Signature=adhoc" not in signing.splitlines():
        raise ValueError("Candidate bundling requires the current local ad-hoc development build")
    parent = entitlements(app)
    worker = app / "Contents/MacOS/info-runtime-worker"
    if worker.is_symlink() or not worker.is_file():
        raise ValueError("Build worker is missing or redirected")
    worker_rights = entitlements(worker)
    if parent.get("com.apple.security.app-sandbox") is not True or worker_rights.get("com.apple.security.inherit") is not True:
        raise ValueError("Owner sandbox or worker inheritance is missing")
    worker_digest = BUILDER.digest(worker)
    record, helper = app / RECORD, app / HELPER
    if not enabled:
        # inspect verified every recorded file and rejected unknown resources;
        # no arbitrary deletion path comes from the manifest or a CLI argument.
        shutil.rmtree(helper)
        record.unlink()
        record.parent.rmdir()
        if not any(helper.parent.iterdir()):
            helper.parent.rmdir()
        seal(app, parent, worker, worker_digest, worker_rights)
        return {"included": False, "modified": True, "capabilityEnabled": False}
    if command(["/usr/bin/lipo", "-archs", str(app / "Contents/MacOS/info_desktop")]).decode().split() != ["arm64"]:
        raise ValueError("Candidate requires an ARM64-only owner build")
    minimum = plistlib.loads((app / "Contents/Info.plist").read_bytes()).get("LSMinimumSystemVersion", "0")
    parts = tuple(map(int, minimum.split(".")))
    if not 1 <= len(parts) <= 3 or any(part < 0 for part in parts) or parts + (0,) * (3 - len(parts)) < (14, 0, 0):
        raise ValueError("Owner minimum system cannot be below the helper's 14.0 target")
    ADAPTATION.mkdir(parents=True, exist_ok=True)
    staged = helper.parent / (".focused-fill-" + uuid.uuid4().hex + ".xpc")
    try:
        with tempfile.TemporaryDirectory(prefix="focus-embed-", dir=ADAPTATION) as work:
            output = Path(work) / "helper-build"
            receipt = (build_helper or BUILDER.build)(output)
            source = output / (BUILDER.SERVICE + ".xpc")
            verify_helper(source, receipt)
            command(["/usr/bin/codesign", "--verify", "--strict", str(source)])
            helper.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(source, staged)
            verify_helper(staged, receipt)
            if previous is not None:
                shutil.rmtree(helper)
            os.replace(staged, helper)
            value = {"format": 1, "kind": "macos-focused-fill-embedded-candidate",
                     "ownerBundleIdentifier": "com.example.infoDesktop", "capabilityEnabled": False,
                     "helper": receipt}
            record.parent.mkdir(parents=True, exist_ok=True)
            temporary = record.with_name("manifest-" + uuid.uuid4().hex + ".tmp")
            try:
                temporary.write_text(json.dumps(value, indent=2) + "\n")
                os.replace(temporary, record)
            finally:
                temporary.unlink(missing_ok=True)
        # Inner code is sealed first; re-sign only the outer app, preserving its
        # existing entitlements/requirements/flags. Never deep-sign other code.
        seal(app, parent, worker, worker_digest, worker_rights)
        inspect(app)
        return {"included": True, "modified": True, "capabilityEnabled": False,
                "helperSourceCommit": receipt["sourceCommit"], "helperExecuted": False}
    finally:
        if staged.exists():
            shutil.rmtree(staged)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--with-focused-fill-candidate", action="store_true")
    args = parser.parse_args()
    try:
        result = assemble(args.app, enabled=args.with_focused_fill_candidate)
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, str(error) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
