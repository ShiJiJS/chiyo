#!/usr/bin/env python3
"""Signed Flutter application lifetime checks with isolated synthetic libraries.

Builds a separate QA entry point, never launches the production entry point or
uses Keychain. Native Cocoa termination must exit normally; SIGKILL is only an
explicit crash case (or marked failed-run cleanup), never a successful quit.
No injected event is counted as a physical button, menu, shortcut or wake event.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="New directory under project build/")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Requires macOS")
    output = args.output.resolve()
    output.relative_to(ROOT / "build")
    output.mkdir(parents=True, exist_ok=False)
    logs = output / "logs"
    logs.mkdir()
    owner = uuid.uuid4().hex
    processes, roots, cases = [], set(), []
    facts = {"complete": False, "cases": cases, "scope":
             "signed Flutter QA entry; real native termination/SQLCipher/processes; synthetic keys/events"}

    def wait_until(predicate, process, timeout=45):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            if process.poll() is not None:
                raise RuntimeError("Probe exited before expected evidence")
            time.sleep(0.05)
        raise TimeoutError("Probe deadline; process state will be preserved in result")

    def launch(mode, label, directory=None):
        environment = os.environ.copy()
        environment.update(INFO_MAC_LIFECYCLE_MODE=mode, INFO_MAC_LIFECYCLE_OWNER=owner)
        if directory is not None:
            environment["INFO_MAC_LIFECYCLE_ROOT"] = str(directory)
        else:
            environment.pop("INFO_MAC_LIFECYCLE_ROOT", None)
        log_path = logs / (label + ".txt")
        with log_path.open("wb") as log:
            process = subprocess.Popen([str(binary)], cwd=ROOT, env=environment,
                                       stdout=log, stderr=subprocess.STDOUT)
        processes.append(process)

        def locate_root():
            for line in log_path.read_text(errors="replace").splitlines():
                if line.startswith("MAC_LIFECYCLE_ROOT="):
                    path = Path(line.split("=", 1)[1])
                    if not path.is_absolute() or path.is_symlink():
                        raise RuntimeError("Invalid probe root")
                    if not path.name.startswith("aim-mac-lifecycle-"):
                        raise RuntimeError("Unexpected probe root")
                    if (path / ".qa-owner").read_text() != owner:
                        raise RuntimeError("Foreign probe root")
                    return path.resolve()
            return None
        actual = wait_until(locate_root, process)
        if directory is not None and actual != directory:
            raise RuntimeError("Probe changed shared library directory")
        roots.add(actual)
        return process, actual

    def report(directory, mode, process=None):
        path = directory / (mode + "-result.json")
        def read():
            try:
                return json.loads(path.read_text())
            except (FileNotFoundError, json.JSONDecodeError):
                return None
        return wait_until(read, process) if process is not None else read()

    def exited(process, directory, mode, label, expected=0):
        code = process.wait(timeout=45)
        result = report(directory, mode)
        if code != expected or not result or result.get("failed"):
            raise RuntimeError(f"{label}: exit={code}; inspect isolated report/log")
        if expected == 0 and not result.get("nativeTerminationRequested"):
            raise RuntimeError("Normal exit did not use native termination")
        case = {"label": label, "exit": code, **result}
        cases.append(case)
        (output / (label + ".json")).write_text(json.dumps(case, indent=2) + "\n")
        return result

    def port_closed(port):
        with socket.socket() as connection:
            connection.settimeout(1)
            return connection.connect_ex(("127.0.0.1", port)) != 0

    def finish(process, directory, mode, label):
        ready = report(directory, mode, process)
        port = ready["port"]
        if port_closed(port):
            raise RuntimeError("Ready service has no listening endpoint")
        (directory / ("finish-" + mode)).touch()
        result = exited(process, directory, mode, label)
        if result.get("libraryCloses") != 1 or not port_closed(port):
            raise RuntimeError("Normal termination failed to close library/endpoint")
        cases[-1]["portClosedAfterExit"] = True

    try:
        source_names = [
            "scripts/qa/macos-lifecycle.py",
            "apps/desktop/integration_test/macos_lifecycle_probe.dart",
            "apps/desktop/lib/desktop_bootstrap.dart",
            "apps/desktop/lib/desktop_runtime.dart",
            "apps/desktop/macos/Runner/AppDelegate.swift",
            "apps/desktop/macos/Runner/MainFlutterWindow.swift",
            "apps/desktop/macos/Runner.xcodeproj/project.pbxproj",
            "apps/desktop/pubspec.lock",
            "packages/info_storage/pubspec.lock",
        ]
        snapshot = output / "sources"
        snapshot.mkdir()
        facts["sourceHashes"] = {}
        for name in source_names:
            content = (ROOT / name).read_bytes()
            facts["sourceHashes"][name] = hashlib.sha256(content).hexdigest()
            (snapshot / (name.replace("/", "-") + ".txt")).write_bytes(content)
        with (logs / "build.txt").open("wb") as log:
            subprocess.run([str(ROOT / "scripts/dev-macos.sh"), "build",
                            "-t", "integration_test/macos_lifecycle_probe.dart"],
                           cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                           timeout=600, check=True)
        source_app = ROOT / "apps/desktop/build/macos/Build/Products/Release/info_desktop.app"
        app = output / "qa/info_desktop.app"
        shutil.copytree(source_app, app, symlinks=True)
        binary = app / "Contents/MacOS/info_desktop"
        facts["executableSha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
        facts["gitHead"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        with (logs / "signature.txt").open("wb") as log:
            subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
                           stdout=log, stderr=subprocess.STDOUT, check=True)
        # Independent processes contend for the same SQLCipher library. The
        # second process must fail before reading its synthetic key store.
        first, folder = launch("hold", "holder")
        first_ready = report(folder, "hold", first)
        if first_ready.get("startup") != "ready":
            raise RuntimeError("First process did not own the library")
        before = hashlib.sha256((folder / "library/library.db").read_bytes()).hexdigest()
        duplicate, _ = launch("duplicate", "duplicate", folder)
        result = exited(duplicate, folder, "duplicate", "duplicate")
        if result["keyReads"] != 0 or result["keyCreates"] != 0:
            raise RuntimeError("Duplicate process reached the key store")
        if hashlib.sha256((folder / "library/library.db").read_bytes()).hexdigest() != before:
            raise RuntimeError("Duplicate startup changed the first process's database")
        finish(first, folder, "hold", "holder-normal-quit")
        recovered, _ = launch("recover", "normal-reopen", folder)
        exited(recovered, folder, "recover", "normal-reopen")

        crashed, crash_folder = launch("hold", "crash-holder")
        crash_ready = report(crash_folder, "hold", crashed)
        crashed.send_signal(signal.SIGKILL)
        if crashed.wait(timeout=10) != -signal.SIGKILL:
            raise RuntimeError("Explicit crash injection did not occur")
        if not port_closed(crash_ready["port"]):
            raise RuntimeError("Crashed process retained its endpoint")
        cases.append({"label": "explicit-app-crash", "exit": -signal.SIGKILL,
                      "faultInjection": True, "portClosedAfterExit": True})
        recovered, _ = launch("recover", "crash-reopen", crash_folder)
        exited(recovered, crash_folder, "recover", "crash-reopen")

        for mode in ["key-failure", "port-busy", "quit-opening", "audit-failure"]:
            process, directory = launch(mode, mode)
            result = exited(process, directory, mode, mode)
            if mode == "quit-opening" and (not result["quitWaitedForOpening"] or result["libraryCloses"] != 1):
                raise RuntimeError("Startup quit failed to release its library")
            if mode == "audit-failure":
                if not result["auditFailurePreventedTermination"] or result["libraryCloses"] != 1:
                    raise RuntimeError("Audit failure was not retained and retried")
                recovered, _ = launch("recover", "audit-reopen", directory)
                exited(recovered, directory, "recover", "audit-reopen")
        for name, digest in facts["sourceHashes"].items():
            if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != digest:
                raise RuntimeError("Source changed during native acceptance")
        facts["complete"] = True
    except Exception as error:
        facts["failure"] = {"type": type(error).__name__, "message": str(error)}
        raise
    finally:
        cleanup = []
        for process in processes:
            if process.poll() is None:
                # This is bounded failed-test cleanup, never counted as quit.
                process.kill()
                process.wait(timeout=10)
                cleanup.append({"pid": process.pid, "forcedFailedRunCleanup": True})
        facts["processCleanup"] = cleanup
        if cleanup:
            facts["complete"] = False
        for directory in roots:
            if directory.is_symlink() or (directory / ".qa-owner").read_text() != owner:
                raise RuntimeError("Refusing foreign directory cleanup")
            # Retain only safe reports. Never publish database/private associations.
            for report_file in directory.glob("*-result.json"):
                dest = output / ("retained-" + directory.name + "-" + report_file.name)
                shutil.copyfile(report_file, dest)
            shutil.rmtree(directory)
        (output / "result.json").write_text(json.dumps(facts, indent=2) + "\n")


if __name__ == "__main__":
    main()
