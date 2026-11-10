#!/usr/bin/env python3
"""Run actual pinned schema16/17 and backup5/6 readers on macOS.

Only synthetic fixtures and fresh extracted sources under build/macos-adaptation
are used. Original production files and dependency locks must remain byte exact.
This proves old-source compatibility on Mac, not Windows-to-Mac transfer or
Keychain/DPAPI behavior. Helpers use controlled keys and executable identities.
"""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[2]
VERSIONS = [
    ("16", "291801046f7d1e6e4217a4bc001ea714689855c5",
     "packages/info_storage/test/support/legacy16_probe.dart"),
    ("17", "299a8b1f9615de218c1fba42d9f383dad377890f",
     "packages/info_storage/test/support/legacy17_probe.dart"),
]


def main():
    if sys.platform != "darwin" or len(sys.argv) != 2:
        raise SystemExit("Usage on Mac: macos-backup-compatibility.py NEW_OUTPUT_DIRECTORY")
    out = Path(sys.argv[1]).resolve()
    out.relative_to(ROOT / "build" / "macos-adaptation")
    out.mkdir(parents=True, exist_ok=False)
    launcher = str(ROOT / "scripts/dev-macos.sh")
    env = os.environ.copy()
    env["PUB_CACHE"] = str(ROOT / ".cache/pub")
    env["PUB_HOSTED_URL"] = "https://pub.dev"
    facts = {"scope": __doc__, "complete": False, "phases": [], "sources": []}
    protected = {}

    def run(name, command, cwd=ROOT, timeout=240):
        with (out / (name + ".log")).open("wb") as log:
            result = subprocess.run(command, cwd=cwd, env=env,
                                    stdout=log, stderr=subprocess.STDOUT,
                                    timeout=timeout)
        facts["phases"].append({"name": name, "exit": result.returncode})
        print(name, result.returncode, flush=True)
        if result.returncode:
            raise RuntimeError(f"{name} failed; inspect its bounded local log")

    def digest(data):
        return hashlib.sha256(data).hexdigest()

    def tree_files(revision):
        return subprocess.check_output([
            "git", "ls-tree", "-r", "--name-only", revision, "--",
            "packages/info_core/lib", "packages/info_storage/lib",
            "packages/info_core/pubspec.yaml", "packages/info_storage/pubspec.yaml",
            "packages/info_core/pubspec.lock", "packages/info_storage/pubspec.lock",
        ], cwd=ROOT, text=True).splitlines()

    try:
        probes = []
        for schema, revision, helper in VERSIONS:
            folder = out / f"schema{schema}-source"
            folder.mkdir()
            archive = out / f"schema{schema}.zip"
            run(f"archive-{schema}", ["git", "archive", "--format=zip", "--output",
                                      str(archive), revision, "packages/info_core",
                                      "packages/info_storage"])
            with zipfile.ZipFile(archive) as source:
                for entry in source.infolist():
                    (folder / entry.filename).resolve().relative_to(folder)
                source.extractall(folder)
            verified = []
            for relative in tree_files(revision):
                expected = subprocess.check_output(["git", "show", f"{revision}:{relative}"], cwd=ROOT)
                actual = (folder / relative).read_bytes()
                assert actual == expected, (revision, relative)
                protected[folder / relative] = digest(actual)
                verified.append({"path": relative, "sha256": digest(actual)})
            package = folder / "packages/info_storage"
            entrypoint = f"legacy{schema}_probe.dart"
            helper_bytes = (ROOT / helper).read_bytes()
            (package / entrypoint).write_bytes(helper_bytes)
            facts["sources"].append({
                "revision": revision, "schema": int(schema),
                "backupFormat": int(schema) - 11,
                "archiveSha256": digest(archive.read_bytes()),
                "helper": helper, "helperSha256": digest(helper_bytes),
                "verifiedProductionFiles": verified,
            })
            run(f"dependencies-{schema}", [launcher, "dart", "pub", "get",
                                          "--enforce-lockfile", "--offline"], cwd=package)
            bundle = out / f"schema{schema}-aot"
            run(f"bundle-{schema}", [launcher, "dart", "build", "cli",
                                     "--target", entrypoint, "--output", str(bundle)], cwd=package)
            binary = bundle / "bundle/bin" / entrypoint.removesuffix(".dart")
            assert binary.is_file()
            facts["sources"][-1]["binarySha256"] = digest(binary.read_bytes())
            probes.append(str(binary))
        for name in ["info_core", "info_storage", "info_cli"]:
            lock = ROOT / "packages" / name / "pubspec.lock"
            protected[lock] = digest(lock.read_bytes())
        env["ISSUE33_LEGACY_PROBE"] = probes[0]
        env["ISSUE35_SCHEMA17_PROBE"] = probes[1]
        env["ISSUE37_OLD_STORAGE_PROBES"] = json.dumps(probes)
        run("legacy-backup-matrix", [launcher, "dart", "test",
            "test/credential_reuse_storage_test.dart",
            "test/focused_fill_storage_test.dart",
            "test/information_delivery_storage_test.dart",
            "test/information_attachments_storage_test.dart",
            "--reporter", "expanded"], cwd=ROOT / "packages/info_storage", timeout=600)
        facts["complete"] = True
    finally:
        changed = [str(file.relative_to(ROOT)) for file, expected in protected.items()
                   if not file.is_file() or digest(file.read_bytes()) != expected]
        facts["unexpectedSourceOrLockChanges"] = changed
        if changed:
            facts["complete"] = False
        (out / "result.json").write_text(json.dumps(facts, indent=2) + "\n")
        if changed:
            raise RuntimeError("Pinned sources or locks changed; preserved for inspection")


if __name__ == "__main__":
    main()
