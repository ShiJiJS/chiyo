#!/usr/bin/env python3
"""Build and inspect a fixed-source ARM64 Mac development package.

Does not install an app, overwrite a delivery, open a production database,
register/trust Codex hooks, alter Keychain, or change Gatekeeper settings.
Python/Xcode/Flutter are builder requirements; shipped programs are AOT.
"""
import argparse
import ctypes
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import stat
import subprocess
import sys
from urllib.parse import unquote, urljoin, urlparse

ROOT = Path(__file__).resolve().parents[1]
SDK = ROOT / ".tools/flutter"
LAUNCHER = str(ROOT / "scripts/dev-macos.sh")
MACHO = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe",
         b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
FOCUS_SPEC = importlib.util.spec_from_file_location("focused_bundle", ROOT / "scripts/bundle-macos-focused-helper.py")
FOCUS_BUNDLE = importlib.util.module_from_spec(FOCUS_SPEC)
FOCUS_SPEC.loader.exec_module(FOCUS_BUNDLE)


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def capture(command, cwd=ROOT):
    return subprocess.check_output(command, cwd=cwd, text=True).strip()


def clean_source(expected=None):
    for args in [["diff", "--quiet"], ["diff", "--cached", "--quiet"]]:
        subprocess.run(["git", *args], cwd=ROOT, check=True)
    if capture(["git", "ls-files", "--others", "--exclude-standard"]):
        raise RuntimeError("Commit untracked source files before packaging")
    commit = capture(["git", "rev-parse", "HEAD"])
    if expected is not None and commit != expected:
        raise RuntimeError("Source changed during packaging")
    return commit


def inventory(root):
    rows = []
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            path.resolve(strict=True).relative_to(root.resolve())
            rows.append({"path": relative, "link": os.readlink(path)})
        elif path.is_file() and relative != "manifest.json":
            rows.append({"path": relative, "bytes": path.stat().st_size,
                         "mode": stat.S_IMODE(path.stat().st_mode),
                         "sha256": digest(path)})
    return rows


def verify_documentation(root):
    """Shipped instructions must link to the shipped directory tree."""
    checked = []
    for name in ["README.md", "CODEX-INTEGRATION.md"]:
        content = (root / name).read_text()
        if re.search(r"@[A-Z_]+@", content):
            raise RuntimeError(f"Unrendered documentation metadata: {name}")
        for target in re.findall(r"\]\(([^\s)]+)\)", content):
            parsed = urlparse(target)
            if parsed.scheme or not parsed.path:
                continue
            path = (root / unquote(parsed.path)).resolve(strict=True)
            path.relative_to(root.resolve())
            checked.append({"document": name, "target": target})
    return checked


def minimum_versions(commands):
    values, command = [], ""
    for line in commands.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0] == "cmd":
            command = parts[1]
        if len(parts) == 2 and (
            (command == "LC_BUILD_VERSION" and parts[0] == "minos") or
            (command == "LC_VERSION_MIN_MACOSX" and parts[0] == "version")
        ):
            values.append(parts[1])
    return values


def os_version(value):
    parts = tuple(map(int, value.split(".")))
    return parts + (0,) * (3 - len(parts))


def cipher_version(path):
    """Check the exact desktop SQLCipher binary in memory, never a library.db."""
    lib = ctypes.CDLL(str(path))
    lib.sqlite3_open.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
    lib.sqlite3_open.restype = ctypes.c_int
    lib.sqlite3_close.argtypes = [ctypes.c_void_p]
    lib.sqlite3_prepare_v2.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int,
                                     ctypes.POINTER(ctypes.c_void_p), ctypes.c_void_p]
    lib.sqlite3_step.argtypes = [ctypes.c_void_p]
    lib.sqlite3_column_text.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.sqlite3_column_text.restype = ctypes.c_char_p
    lib.sqlite3_finalize.argtypes = [ctypes.c_void_p]
    db, statement = ctypes.c_void_p(), ctypes.c_void_p()
    if lib.sqlite3_open(b":memory:", ctypes.byref(db)) != 0:
        raise RuntimeError("Desktop SQLCipher memory probe failed")
    try:
        if lib.sqlite3_prepare_v2(db, b"PRAGMA cipher_version", -1, ctypes.byref(statement), None) != 0:
            raise RuntimeError("Desktop cipher version unavailable")
        if lib.sqlite3_step(statement) != 100:
            raise RuntimeError("Desktop cipher row missing")
        version = lib.sqlite3_column_text(statement, 0).decode()
        if not version.startswith("4."):
            raise RuntimeError("Desktop SQLCipher 4 required")
        return version
    finally:
        if statement:
            lib.sqlite3_finalize(statement)
        lib.sqlite3_close(db)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="NEW directory under this checkout's build/")
    parser.add_argument("--check", action="store_true", help="Also run all four source test suites")
    parser.add_argument("--with-focused-fill-candidate", action="store_true",
                        help="Embed the disabled native XPC candidate; no permission, input or capability activation")
    args = parser.parse_args()
    if sys.platform != "darwin" or platform.machine() != "arm64":
        parser.error("Build on ARM64 macOS")
    output = args.output.resolve()
    output.relative_to(ROOT / "build")
    if output.exists() or output.is_symlink():
        parser.error("Output already exists")
    commit = clean_source()
    output.mkdir(parents=True)
    logs = output / "logs"
    logs.mkdir()
    facts = {"sourceCommit": commit, "complete": False, "phases": []}
    environment = os.environ.copy()
    environment["FLUTTER_MACOS_ARM64_ONLY"] = "true"

    def run(name, command, *, cwd=ROOT, env=None, input_text=None, timeout=600):
        with (logs / f"{name}.txt").open("wb") as log:
            try:
                result = subprocess.run(command, cwd=cwd, env=env or environment,
                                        input=None if input_text is None else input_text.encode(),
                                        stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
                code = result.returncode
            except subprocess.TimeoutExpired:
                code = 124
        facts["phases"].append({"name": name, "exit": code})
        print(name, code, flush=True)
        if code:
            raise RuntimeError(f"{name} failed; see {logs / (name + '.txt')}")

    try:
        if args.check:
            run("source-checks", [LAUNCHER, "check"], timeout=1800)
        build_arguments = [LAUNCHER, "build"]
        if args.with_focused_fill_candidate:
            build_arguments.append("--with-focused-fill-candidate")
        run("release-build", build_arguments)
        clean_source(commit)
        payload = output / "AgentInfoManage"
        app = payload / "app/info_desktop.app"
        app.parent.mkdir(parents=True)
        shutil.copytree(ROOT / "apps/desktop/build/macos/Build/Products/Release/info_desktop.app",
                        app, symlinks=True)
        focus = FOCUS_BUNDLE.inspect(app)
        if (focus is not None) != args.with_focused_fill_candidate:
            raise RuntimeError("Focused-fill candidate state differs from the requested package")
        cli = payload / "cli"
        cli.mkdir()
        for entry, name in [
            ("info", "info"), ("codex_info", "info-codex"),
            ("codex_hook", "info-codex-hook"), ("runtime_worker", "info-runtime-worker"),
            ("prepare_codex", "info-prepare-codex"),
        ]:
            run(f"compile-{name}", [LAUNCHER, "dart", "compile", "exe",
                "--target-os", "macos", "--target-arch", "arm64",
                f"bin/{entry}.dart", "-o", str(cli / name)], cwd=ROOT / "packages/info_cli")
            run(f"sign-{name}", ["/usr/bin/codesign", "--force", "--sign", "-", str(cli / name)])
        shutil.copytree(ROOT / "integrations/codex/skills/agent-info-access", cli / "template")
        run("diagnostic-build", [LAUNCHER, "dart", "build", "cli", "--target-os", "macos",
            "--target-arch", "arm64", "--target", "bin/macos-storage-check.dart",
            "--output", str(output / "diagnostic-build")], cwd=ROOT / "packages/info_storage")
        shutil.copytree(output / "diagnostic-build/bundle", payload / "diagnostics", symlinks=True)
        for binary in (payload / "diagnostics").rglob("*"):
            if binary.is_file() and binary.read_bytes()[:4] in MACHO:
                run("sign-diagnostic-" + binary.name, ["/usr/bin/codesign", "--force", "--sign", "-", str(binary)])

        notices, provenance = payload / "notices", payload / "provenance"
        notices.mkdir()
        provenance.mkdir()
        for source, name in [
            (SDK / "LICENSE", "Flutter-LICENSE"),
            (SDK / "bin/cache/dart-sdk/LICENSE", "Dart-LICENSE"),
            (SDK / "bin/cache/LICENSE.dart_sdk_archive.md", "Dart-THIRD-PARTY-NOTICES.md"),
            (SDK / "bin/cache/artifacts/engine/darwin-x64-release/LICENSE.artifacts.md", "Flutter-engine-NOTICES.md"),
            (ROOT / "third_party/SQLCipher-LICENSE.md", "SQLCipher-LICENSE.md"),
            (ROOT / "apps/desktop/assets/fonts/OFL.txt", "NotoSansSC-OFL.txt"),
        ]:
            shutil.copy2(source, notices / name)
        dependencies = {}
        for package in ["packages/info_core", "packages/info_cli", "packages/info_storage", "apps/desktop"]:
            config = ROOT / package / ".dart_tool/package_config.json"
            for dependency in json.loads(config.read_text())["packages"]:
                base = Path(unquote(urlparse(urljoin(config.as_uri(), dependency["rootUri"])).path))
                name = dependency["name"]
                if name in dependencies:
                    continue
                dependencies[name] = base
                for notice in base.iterdir():
                    if notice.is_file() and re.match(r"^(LICENSE|LICENCE|NOTICE|COPYING)(\.|$)", notice.name):
                        shutil.copy2(notice, notices / f"{name}-{notice.name}")
            shutil.copy2(ROOT / package / "pubspec.lock", provenance / (package.replace("/", "-") + "-pubspec.lock"))
        shutil.copy2(dependencies["sqlite3"] / "lib/src/hook/asset_hashes.dart",
                     provenance / "sqlite3-native-asset-hashes.dart")
        tools_root = app / "Contents/Resources/ThirdParty"
        tools_manifest = json.loads((tools_root / "manifest.json").read_text())
        locked_tools = json.loads((ROOT / "third_party/macos-tools.json").read_text())
        if {key: tools_manifest[key] for key in locked_tools} != locked_tools:
            raise RuntimeError("Bundled tools differ from the source lock")
        # The inner manifest describes the complete original publisher payload,
        # including notices, modes and internal symlinks. Do not trust entry hashes alone.
        if inventory(tools_root) != tools_manifest["files"]:
            raise RuntimeError("Bundled tool dependency tree differs")
        shutil.copy2(tools_root / "manifest.json", provenance / "macos-tools.json")
        shutil.copytree(tools_root / "notices", notices / "macos-tools")
        shutil.copy2(ROOT / "integrations/codex/MACOS-INTEGRATION.md", payload / "CODEX-INTEGRATION.md")
        # A sandboxed app cannot read its enclosing delivery directory. Keep a
        # same-source integration payload inside its signed resources. External
        # CLI paths remain available for existing host installations.
        embedded = app / "Contents/Resources/AgentIntegration"
        shutil.copytree(cli, embedded / "cli")
        shutil.copy2(payload / "CODEX-INTEGRATION.md", embedded / "CODEX-INTEGRATION.md")
        identity = {"appIdentity": "com.example.infoDesktop", "sourceCommit": commit}
        (app / "Contents/Resources/agent-source.json").write_text(json.dumps(identity) + "\n")
        (embedded / "manifest.json").write_text(json.dumps({
            "format": 2, "scope": "app_integration", "architecture": "macos-arm64",
            "sourceDirty": False, **identity, "files": inventory(embedded),
        }, indent=2) + "\n")
        entitlement_file = output / "app-entitlements.plist"
        entitlement_file.write_bytes(subprocess.check_output(
            ["/usr/bin/codesign", "-d", "--entitlements", ":-", str(app)], stderr=subprocess.DEVNULL))
        run("sign-app-integration", ["/usr/bin/codesign", "--force", "--sign", "-",
            "--entitlements", str(entitlement_file), str(app)])
        notice_archives = list(app.rglob("NOTICES.Z"))
        if len(notice_archives) != 1:
            raise RuntimeError("Expected Flutter's bundled license registry")
        (notices / "Flutter-app-NOTICES.txt").write_bytes(gzip.decompress(notice_archives[0].read_bytes()))

        primary = [
            app / "Contents/MacOS/info_desktop", app / "Contents/MacOS/info-runtime-worker",
            *[cli / name for name in ["info", "info-codex", "info-codex-hook", "info-runtime-worker", "info-prepare-codex"]],
            payload / "diagnostics/bin/macos-storage-check",
        ]
        if focus is not None:
            if focus["helper"]["sourceCommit"] != commit or focus["helper"]["sourceInputsDirty"]:
                raise RuntimeError("Focused-fill helper differs from the fixed clean source")
            primary.append(app / FOCUS_BUNDLE.HELPER / "Contents/MacOS/AgentInfoFocusedFill")
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        minimum = os_version(info["LSMinimumSystemVersion"])
        architecture = []
        for binary in payload.rglob("*"):
            if binary.is_symlink() or not binary.is_file():
                continue
            with binary.open("rb") as stream:
                if stream.read(4) not in MACHO:
                    continue
            archs = capture(["/usr/bin/lipo", "-archs", str(binary)]).split()
            if "arm64" not in archs or (binary in primary and archs != ["arm64"]):
                raise RuntimeError(f"Architecture mismatch: {binary}")
            load_commands = capture(["/usr/bin/otool", "-l", str(binary)])
            minima = minimum_versions(load_commands)
            if not minima or any(os_version(value) > minimum for value in minima):
                raise RuntimeError(f"Payload minimum OS exceeds application: {binary}")
            for line in capture(["/usr/bin/otool", "-L", str(binary)]).splitlines()[1:]:
                if line.endswith("):"):
                    continue  # Universal binaries have a header for each slice.
                dependency = line.strip().split(" (", 1)[0]
                if dependency.startswith("/") and not dependency.startswith(("/usr/lib/", "/System/Library/")):
                    # A dylib's first entry is its own install name; packaged
                    # native assets use @rpath. No build-machine library paths.
                    raise RuntimeError(f"Non-system absolute dependency: {dependency}")
            architecture.append({"path": binary.relative_to(payload).as_posix(), "architectures": archs,
                                 "minimumOS": sorted(set(minima))})
        if any(not binary.is_file() for binary in primary):
            raise RuntimeError("Required executable missing")
        run("app-signature", ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
        entitlements = plistlib.loads(subprocess.check_output(
            ["/usr/bin/codesign", "-d", "--entitlements", ":-", str(app)], stderr=subprocess.DEVNULL))
        worker_entitlements = plistlib.loads(subprocess.check_output(
            ["/usr/bin/codesign", "-d", "--entitlements", ":-", str(primary[1])], stderr=subprocess.DEVNULL))
        if not entitlements.get("com.apple.security.app-sandbox") or not worker_entitlements.get("com.apple.security.inherit"):
            raise RuntimeError("App sandbox or worker inheritance is missing")
        if entitlements.get("com.apple.security.get-task-allow"):
            raise RuntimeError("Release app must not carry the debugger entitlement")
        if info["CFBundleIdentifier"] != "com.example.infoDesktop":
            raise RuntimeError("Unexpected app identity")
        cipher = app / "Contents/Frameworks/sqlcipher.framework/Versions/A/sqlcipher"
        version = re.search(r"^version:\s*(.+)$", (ROOT / "apps/desktop/pubspec.yaml").read_text(), re.M).group(1)
        release = f"{version}-mac-dev.{commit[:12]}"
        if focus is not None:
            release += "-focused-fill-candidate"
        readme = (ROOT / "integrations/macos/README.md").read_text()
        for token, value in {
            "@RELEASE@": release, "@SOURCE_COMMIT@": commit,
            "@MINIMUM_MACOS@": info["LSMinimumSystemVersion"],
            "@TESTED_MACOS@": platform.mac_ver()[0],
        }.items():
            if token not in readme:
                raise RuntimeError(f"Missing package README metadata: {token}")
            readme = readme.replace(token, value)
        (payload / "README.md").write_text(readme)
        manifest = {
            "format": 1, "product": "Agent Info Manage", "release": release,
            "sourceCommit": commit, "sourceDirty": False, "architecture": "macos-arm64",
            "appIdentity": info["CFBundleIdentifier"], "minimumSystemVersion": info["LSMinimumSystemVersion"],
            "testedBuildHost": platform.mac_ver()[0], "signing": "local ad-hoc development; not notarized",
            "sdkRequiredAtRuntime": False,
            "verificationScope": "build and extracted synthetic checks; no clean-user, Keychain upgrade, native UI or real Codex acceptance",
            "sourceChecksRequested": args.check,
            "flutterRevision": capture(["git", "-C", str(SDK), "rev-parse", "HEAD"]),
            "macosAotCompatibility": {
                "upstreamIssue": "https://github.com/flutter/flutter/issues/191575",
                "buildScriptSha256": digest(ROOT / "scripts/build-macos-release.py"),
                "scope": "compile unused experimental windowing as false; restore SDK source after build",
            },
            "dart": capture([str(SDK / "bin/cache/dart-sdk/bin/dart"), "--version"]),
            "sqlcipher": {"desktopSha256": digest(cipher), "desktopCipherVersion": cipher_version(cipher)},
            "appEntitlements": entitlements, "workerEntitlements": worker_entitlements,
            "credentialTools": tools_manifest["tools"],
            "machO": architecture, "files": inventory(payload),
        }
        if focus is not None:
            manifest["focusedFillCandidate"] = {"included": True, "capabilityEnabled": False,
                "systemAcceptance": False, "helper": focus["helper"]}
        clean_source(commit)
        (payload / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        archive = output / f"agent-info-manage-{release}-macos-arm64.zip"
        run("archive", ["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(payload), str(archive)])
        (output / (archive.name + ".sha256")).write_text(f"{digest(archive)}  {archive.name}\n")
        extracted = output / "verify/中文 空格 路径"
        extracted.mkdir(parents=True)
        run("extract", ["/usr/bin/ditto", "-x", "-k", str(archive), str(extracted)])
        final = extracted / "AgentInfoManage"
        if inventory(final) != manifest["files"]:
            raise RuntimeError("Extracted bytes, permissions or symlinks differ")
        if (final / "manifest.json").read_bytes() != (payload / "manifest.json").read_bytes():
            raise RuntimeError("Extracted manifest differs")
        if FOCUS_BUNDLE.inspect(final / "app/info_desktop.app") != focus:
            raise RuntimeError("Extracted focused-fill candidate differs")
        facts["shippedDocumentationLinks"] = verify_documentation(final)
        run("extracted-app-signature", ["/usr/bin/codesign", "--verify", "--deep", "--strict",
                                       str(final / "app/info_desktop.app")])
        temporary = output / "verify/tmp"
        temporary.mkdir()
        minimal = {"PATH": "/usr/bin:/bin", "TMPDIR": str(temporary) + "/"}
        run("extracted-storage", [str(final / "diagnostics/bin/macos-storage-check")], env=minimal)
        diagnostic = json.loads((logs / "extracted-storage.txt").read_text())
        if diagnostic.get("status") != "ok" or diagnostic["cipherVersion"] != manifest["sqlcipher"]["desktopCipherVersion"]:
            raise RuntimeError("Extracted diagnostic did not confirm matching SQLCipher")
        test_env = environment | {
            "INFO_TEST_DELIVERY": str(final),
            "INFO_TEST_MAC_WORKER": str(final / "cli/info-runtime-worker"),
        }
        run("extracted-cli-and-worker", [LAUNCHER, "dart", "test",
            "test/bundle_preparation_test.dart", "test/macos_worker_lifetime_test.dart",
            "--reporter", "expanded"], cwd=ROOT / "packages/info_cli", env=test_env)
        clean_source(commit)
        facts.update(complete=True, archive=archive.name, archiveSha256=digest(archive),
                     scope=manifest["verificationScope"], extractedDirectory=str(final.relative_to(output)))
        print("Verified local development package:", archive, flush=True)
    finally:
        (output / "verification.json").write_text(json.dumps(facts, indent=2) + "\n")


if __name__ == "__main__":
    main()
