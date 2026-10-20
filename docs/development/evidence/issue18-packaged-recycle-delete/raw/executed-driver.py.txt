"""Finish one human-confirmed UI deletion of a preserved synthetic version3 file.

Requires the frozen previous run's library hash proof; no new fixture is made.
The operator approves a fresh CLI request, observes the exact version3 delete
modal, and only after human action-time confirmation clicks Confirm delete.
The private CLI peer checks old scope denial and automatic copy cleanup. The
operator then restores via the real recycle UI, approves the new field, and
observes recycle/history before writing final-observed.json. Receipts describe
actual observations, not image recognition. This driver never clicks any UI.
Normal exits address only this Popen child, with no force-kill fallback. Full
success removes only the validated owned temporary root; failures preserve it.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import queue
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

sys.stdout.reconfigure(encoding="utf-8")
parser = argparse.ArgumentParser(description=__doc__)
for name in ["delivery", "dart", "evidence", "prior-proof"]:
    parser.add_argument("--" + name, type=Path, required=True)
args = parser.parse_args()
if sys.platform != "win32":
    parser.error("Windows required")
root = Path(__file__).resolve().parent.parent
proof_path = args.prior_proof.resolve(strict=True)
proof = json.loads(proof_path.read_text(encoding="utf-8"))
temp = Path(proof["root"])
assert not temp.is_symlink() and not temp.is_junction() and temp == temp.resolve(strict=True)
assert temp.parent == Path(tempfile.gettempdir()).resolve() and temp.name.startswith("aim-packaged-recycle-ui-")
assert not any(f.is_symlink() or f.is_junction() for f in temp.rglob("*"))
for row in proof["files"]:
    file = (temp / row["path"]).resolve(strict=True)
    assert file.is_relative_to(temp)
    assert file.stat().st_size == row["bytes"] and hashlib.sha256(file.read_bytes()).hexdigest() == row["sha256"]
out = args.evidence.resolve()
out.mkdir(parents=True, exist_ok=False)
payload = args.delivery.resolve(strict=True)
manifest = json.loads((payload / "manifest.json").read_text(encoding="utf-8-sig"))
for row in manifest["files"]:
    file = (payload / row["path"]).resolve(strict=True)
    assert file.is_relative_to(payload)
    assert file.stat().st_size == row["bytes"] and hashlib.sha256(file.read_bytes()).hexdigest() == row["sha256"]
app, cli, dart = payload / "app/info_desktop.exe", payload / "cli/info.exe", str(args.dart.resolve(strict=True))
env = os.environ.copy()
env.update(PUB_HOSTED_URL="https://pub.flutter-io.cn", FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn")
locks = {root / name / "pubspec.lock": (root / name / "pubspec.lock").read_bytes()
         for name in ["packages/info_core", "packages/info_cli", "packages/info_storage", "apps/desktop"]}
normalize = lambda b: b.replace(b"https://pub.flutter-io.cn", b"https://pub.dev").replace(b"\r\n", b"\n")
facts = {"productSource": manifest["sourceCommit"], "complete": False, "checks": [],
         "priorProof": {"path": str(proof_path), "sha256": hashlib.sha256(proof_path.read_bytes()).hexdigest()}}
process = peer = None
streams = []


def check(name, condition, **data):
    facts["checks"].append(dict(check=name, passed=bool(condition), **data))
    assert condition, name


def phase(name, **data):
    value = dict(phase=name, **data)
    text = json.dumps(value, ensure_ascii=False)
    (out / "phase.json").write_text(text + "\n", encoding="utf-8")
    with (out / "phases.jsonl").open("a", encoding="utf-8") as log:
        log.write(text + "\n")
    print(text, flush=True)


def run(name, arguments):
    with (out / (name + ".txt")).open("wb") as log:
        result = subprocess.run([dart, *arguments], cwd=root / "packages/info_storage", env=env,
                                stdout=log, stderr=subprocess.STDOUT, timeout=120)
    check(name, result.returncode == 0)
    text = (out / (name + ".txt")).read_text(encoding="utf-8", errors="replace")
    start = text.find('{"status":')
    return json.loads(text[start:].strip()) if start >= 0 else None


def inspect(action):
    return run(action, ["run", "test/support/packaged_recycle_ui_fixture.dart", action, str(temp)])


class Peer:
    def __init__(self):
        log = (out / "cli-stderr.txt").open("wb")
        streams.append(log)
        self.child = subprocess.Popen([str(cli)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                      stderr=log, text=True, encoding="utf-8", creationflags=subprocess.CREATE_NO_WINDOW)
        self.lines = queue.Queue()

        def read():
            for line in self.child.stdout:
                self.lines.put(line)
        threading.Thread(target=read, daemon=True).start()

    def call(self, command, **data):
        self.child.stdin.write(json.dumps(dict(command=command, **data)) + "\n")
        self.child.stdin.flush()
        return json.loads(self.lines.get(timeout=45))

    def close(self):
        self.child.stdin.close()
        assert self.child.wait(timeout=10) == 0


def wait_until(test, timeout=600):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        assert process.poll() is None
        value = test()
        if value:
            return value
        time.sleep(.3)
    raise TimeoutError("Bounded actual UI observation missing")


def stop():
    result = subprocess.run([str(cli), "app", "quit", "--pid", str(process.pid)], capture_output=True,
                            text=True, encoding="utf-8", timeout=65, creationflags=subprocess.CREATE_NO_WINDOW)
    check("actual-normal-exit", result.returncode == 0 and json.loads(result.stdout)["status"] == "exited"
          and process.wait(timeout=5) == 0, processId=process.pid)


def request_file(item, field, label):
    request = peer.call("request", purpose="最终包虚构简历删除恢复验收：" + label,
                        fields=[dict(itemId=item, fieldId=field)])
    check(label + "-request-pending", request["status"] == "pending")
    request_id = request["requestId"]
    phase("approve-" + label, pid=process.pid, requestId=request_id)
    def decided():
        value = peer.call("status", requestId=request_id)
        return value if value["status"] != "pending" else None
    check(label + "-ui-approved", wait_until(decided)["status"] == "approved")
    grant = peer.call("claim", requestId=request_id)
    check(label + "-claimed", grant["status"] == "ok")
    return request_id, grant["expiresAt"]


def fetch(request, item, field, operation):
    result = peer.call("file-fetch", requestId=request, itemId=item, fieldId=field, operationId=operation)
    check(operation + "-ready", result["status"] == "ok" and result["delivery"]["state"] == "ready")
    delivery = result["delivery"]
    check(operation + "-original-bytes", Path(delivery["path"]).read_bytes() == (temp / "synthetic-resume.txt").read_bytes())
    return delivery


def deny(request, item, field, operation, code):
    result = peer.call("file-fetch", requestId=request, itemId=item, fieldId=field, operationId=operation)
    check(operation + "-denied", result.get("errorCode") == code and result.get("operationClaimed") is False
          and "delivery" not in result, status=result.get("status"), errorCode=result.get("errorCode"))


try:
    for file, before in locks.items():
        file.write_bytes(before.replace(b"https://pub.dev", b"https://pub.flutter-io.cn"))
    run("format", ["format", "test/support/packaged_recycle_ui_fixture.dart"])
    run("pub", ["pub", "get", "--offline", "--enforce-lockfile"])
    run("analyze", ["analyze", "--fatal-infos"])
    before = inspect("inspect")
    check("same-version3-target", before["itemVersion"] == 3 and before["information"] == 1
          and before["originalMatches"] and before["deliveries"] == 1 and before["activeGrants"] == 0)
    with socket.socket() as available:
        available.bind(("127.0.0.1", 47125))
    child = env.copy()
    child["LOCALAPPDATA"] = str(temp / "profile")
    log = (out / "app.txt").open("wb")
    streams.append(log)
    process = subprocess.Popen([str(app)], cwd=app.parent, env=child, stdin=subprocess.DEVNULL,
                               stdout=log, stderr=subprocess.STDOUT)
    peer = Peer()
    wait_until(lambda: peer.call("capabilities").get("status") == "ok", 30)
    port = subprocess.run(["powershell", "-NoProfile", "-Command", "Get-NetTCPConnection -LocalPort 47125 -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique"], capture_output=True, text=True, timeout=15)
    check("port-owned-by-child", port.stdout.strip() == str(process.pid), processId=process.pid)
    check("fresh-session", peer.call("session", chatLabel="最终包界面删除恢复验收")["status"] == "ok")
    items = peer.call("catalog")["items"]
    expected = json.loads((temp / "expected.json").read_text(encoding="utf-8"))
    check("confirmed-synthetic-target-only", len(items) == 1 and items[0]["id"] == expected["itemId"]
          and items[0]["name"] == "虚构回收验收简历" and items[0]["version"] == 3
          and len(items[0]["fields"]) == 1 and items[0]["fields"][0]["kind"] == "file" and expected["bytes"] == 76)
    item, field = items[0]["id"], items[0]["fields"][0]["id"]
    (temp / "tail-expected.json").write_text(json.dumps(dict(itemId=item, fieldId=field)), encoding="utf-8")
    old_request, deadline = request_file(item, field, "before-delete")
    held = fetch(old_request, item, field, "before-delete")
    phase("confirm-human-approved-version3-deletion", pid=process.pid, itemId=item, version=3,
          itemName="虚构回收验收简历", bytes=76)
    wait_until(lambda: not peer.call("catalog")["items"])
    deny(old_request, item, field, "after-delete", "field_removed")
    def copy_expired():
        value = peer.call("file-status", deliveryId=held["deliveryId"])
        return value if value.get("delivery", {}).get("state") == "expired" else None
    expired = wait_until(copy_expired, 30)
    check("deletion-cleans-existing-copy", expired["delivery"]["errorCode"] == "field_removed"
          and "path" not in expired["delivery"] and not Path(held["path"]).exists())
    phase("restore-actual-ui-deleted-file", pid=process.pid, receipt=str(out / "delete-observed.json"))
    receipt = out / "delete-observed.json"
    wait_until(receipt.is_file)
    observed = json.loads(receipt.read_text(encoding="utf-8"))
    check("actual-delete-observed-and-human-confirmed", observed["observed"] and observed["userConfirmed"])
    restored = wait_until(lambda: peer.call("catalog").get("items"))
    check("ui-restore-creates-new-field", len(restored) == 1 and restored[0]["id"] == item
          and restored[0]["version"] == 5 and restored[0]["fields"][0]["id"] != field)
    new_field = restored[0]["fields"][0]["id"]
    deny(old_request, item, field, "old-field-after-restore", "field_removed")
    deny(old_request, item, new_field, "new-field-with-old-grant", "not_authorized")
    old_claim = peer.call("claim", requestId=old_request)
    check("old-grant-deadline-not-extended", old_claim["status"] == "ok" and old_claim["expiresAt"] == deadline)
    new_request, _ = request_file(item, new_field, "after-restore")
    delivered = fetch(new_request, item, new_field, "after-restore")
    released = peer.call("file-release", deliveryId=delivered["deliveryId"])
    check("new-copy-released", released["status"] == "ok" and released["delivery"]["state"] == "released"
          and not Path(delivered["path"]).exists())
    phase("observe-final-recycle-and-history", pid=process.pid, receipt=str(out / "final-observed.json"))
    receipt = out / "final-observed.json"
    wait_until(receipt.is_file)
    check("final-ui-observed", json.loads(receipt.read_text(encoding="utf-8"))["observed"])
    stop()
    final = inspect("inspect-completed")
    facts["inspection"] = final
    check("durable-ui-delete-restore-and-scope-invalidation", final["information"] == 1
          and all(final[k] for k in ["itemIdentityPreserved", "fieldIdentityChanged", "fieldIdentityChangedFromV3",
                                    "attachmentIdentityPreserved", "originalMatches", "noHeldCopies", "restoredFieldMappingMatches"])
          and final["itemVersion"] == 5 and final["availableRecycle"] == 0 and final["activeGrants"] == 0
          and final["restoredRecycle"] == final["deletionFacts"] == final["restoreFacts"] == 2
          and final["deliveries"] == 3 and final["expiredRemovedDeliveries"] == 1 and final["releasedDeliveries"] == 2)
    facts["complete"] = True
    phase("complete")
finally:
    if process is not None and process.poll() is None:
        stop()
    if peer is not None:
        peer.close()
    for stream in streams:
        stream.close()
    bad = []
    for file, before in locks.items():
        if normalize(file.read_bytes()) != normalize(before):
            bad.append(str(file))
        else:
            file.write_bytes(before)
    facts["unexpectedLocks"] = bad
    if facts["complete"]:
        assert temp.parent == Path(tempfile.gettempdir()).resolve() and temp.name.startswith("aim-packaged-recycle-ui-")
        assert not temp.is_symlink() and not temp.is_junction()
        assert not any(f.is_symlink() or f.is_junction() for f in temp.rglob("*"))
        shutil.rmtree(temp)
        facts["temporaryRemoved"] = not temp.exists()
    else:
        facts["preservedTemporary"] = str(temp)
    (out / "result.json").write_text(json.dumps(facts, indent=2) + "\n", encoding="utf-8")
    assert not bad, bad
