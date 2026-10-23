#!/usr/bin/env python3
"""Build genuine format22 source and check current SQLCipher portable migration.

No GUI, Keychain, Windows CI, production profiles or native input. All old-source
copies/AOT bundles are temporary; retain only source identity and bounded logs.
"""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE22 = "0eb8ece5d56c716bd93ddddb550e45871ec8774a"
LAUNCHER = str(ROOT / "scripts/dev-macos.sh")


def main():
    output = ROOT / "build/macos-adaptation/issue51-portable-format"
    output.mkdir(parents=True, exist_ok=True)
    facts = {"format": 1, "oldReaderSource": SOURCE22, "complete": False,
             "scope": "real SQLCipher and old Dart source on macOS; no Windows-native/system/UI acceptance",
             "phases": [], "productionLibraryOpened": False, "osKeyStoreUsed": False,
             "nativeInputExecuted": False, "windowsCIExecuted": False}
    def run(name, arguments, cwd, env=None, timeout=60):
        with (output / (name + ".txt")).open("wb") as log:
            result = subprocess.run(arguments, cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
        facts["phases"].append({"name": name, "exit": result.returncode})
        if result.returncode:
            raise RuntimeError(f"{name} failed; see {output / (name + '.txt')}")
    try:
        with tempfile.TemporaryDirectory(prefix="old-source-", dir=output) as temporary:
            snapshot = Path(temporary)
            archive = subprocess.check_output(["git", "archive", SOURCE22, "packages/info_core", "packages/info_storage"], cwd=ROOT)
            with tarfile.open(fileobj=io.BytesIO(archive)) as source:
                for member in source.getmembers():
                    if member.issym() or member.islnk() or not (member.isfile() or member.isdir()):
                        raise RuntimeError("Unexpected old-source archive entry")
                    destination = snapshot / member.name
                    destination.resolve().relative_to(snapshot.resolve())
                    if member.isdir(): destination.mkdir(parents=True, exist_ok=True)
                    else:
                        destination.parent.mkdir(parents=True, exist_ok=True)
                        destination.write_bytes(source.extractfile(member).read())
            package = snapshot / "packages/info_storage"
            library = package / "lib/info_storage.dart"
            if "const _libraryFormat = 22;" not in library.read_text() or "_portableFocusedFillLibraryFormat" in library.read_text():
                raise RuntimeError("Baseline is not the genuine format22 reader")
            facts["oldStorageSourceSha256"] = hashlib.sha256(library.read_bytes()).hexdigest()
            entry = package / "bin/format22-reader.dart"
            entry.parent.mkdir(exist_ok=True)
            entry.write_bytes((ROOT / "packages/info_storage/test/support/format22_reader.dart").read_bytes())
            run("old-pub-get", [LAUNCHER, "dart", "pub", "get", "--offline", "--enforce-lockfile"], package)
            bundle = snapshot / "reader"
            run("old-compile", [LAUNCHER, "dart", "build", "cli", "--target-os", "macos", "--target-arch", "arm64",
                                "--target", "bin/format22-reader.dart", "--output", str(bundle)], package)
            probe = bundle / "bundle/bin/format22-reader"
            if not probe.is_file(): raise RuntimeError("Old reader executable missing")
            facts["oldReaderExecutableSha256"] = hashlib.sha256(probe.read_bytes()).hexdigest()
            environment = os.environ | {"INFO_TEST_FORMAT22_PROBE": str(probe)}
            run("portable-tests", [LAUNCHER, "dart", "test", "test/focused_fill_storage_test.dart", "--reporter", "expanded"],
                ROOT / "packages/info_storage", env=environment)
        facts.update(complete=True, temporaryOldSourceAndBinaryRemoved=True)
    finally:
        (output / "verification.json").write_text(json.dumps(facts, indent=2) + "\n")
    print(json.dumps({"complete": facts["complete"], "oldReaderSource": SOURCE22, "temporaryOldSourceAndBinaryRemoved": True}))


if __name__ == "__main__":
    main()
