"""Actual packaged UI restores an Owner-fixture recycled synthetic file.

The fixture's initial deletion is SDK setup, never reported as UI deletion.
An operator restores it through UI, explicitly approves a fresh CLI request,
and inspects the final delete confirmation without clicking Confirm delete.
Write preview-observed.json only after observing that actual dialog. Its
deletion is deferred until separate action-time confirmation; this run only
certifies restore/new authorization. Normal exit preserves the owned root for
that later test. No force-kill fallback or real user library/configuration.
"""
from pathlib import Path
import argparse, hashlib, json, os, queue, socket, subprocess, sys, tempfile, threading, time

sys.stdout.reconfigure(encoding='utf-8')
p = argparse.ArgumentParser(description=__doc__)
for name in ['delivery', 'dart', 'evidence']:
    p.add_argument('--' + name, type=Path, required=True)
a = p.parse_args()
if sys.platform != 'win32':
    p.error('Windows required')
r = Path(__file__).resolve().parent.parent
out = a.evidence.resolve(); out.mkdir(parents=True, exist_ok=False)
payload = a.delivery.resolve(strict=True)
manifest = json.loads((payload / 'manifest.json').read_text(encoding='utf-8-sig'))
for row in manifest['files']:
    file = (payload / row['path']).resolve(strict=True)
    assert file.is_relative_to(payload)
    assert file.stat().st_size == row['bytes'] and hashlib.sha256(file.read_bytes()).hexdigest() == row['sha256']
app, cli, dart = payload / 'app/info_desktop.exe', payload / 'cli/info.exe', str(a.dart.resolve(strict=True))
temp = Path(tempfile.mkdtemp(prefix='aim-packaged-recycle-ui-')).resolve()
assert temp.parent == Path(tempfile.gettempdir()).resolve()
env = os.environ.copy()
env.update(PUB_HOSTED_URL='https://pub.flutter-io.cn', FLUTTER_STORAGE_BASE_URL='https://storage.flutter-io.cn')
locks = {r / name / 'pubspec.lock': (r / name / 'pubspec.lock').read_bytes()
         for name in ['packages/info_core', 'packages/info_cli', 'packages/info_storage', 'apps/desktop']}
normalize = lambda b: b.replace(b'https://pub.flutter-io.cn', b'https://pub.dev').replace(b'\r\n', b'\n')
facts = {'productSource': manifest['sourceCommit'], 'restoreComplete': False,
         'uiDeletionExecuted': False, 'initialDeletion': 'Owner fixture setup only', 'checks': []}
process = peer = None
streams = []


def check(name, condition, **data):
    facts['checks'].append(dict(check=name, passed=bool(condition), **data)); assert condition, name


def phase(name, **data):
    value = dict(phase=name, **data)
    (out / 'phase.json').write_text(json.dumps(value, ensure_ascii=False) + '\n', encoding='utf-8')
    with (out / 'phases.jsonl').open('a', encoding='utf-8') as log:
        log.write(json.dumps(value, ensure_ascii=False) + '\n')
    print(json.dumps(value, ensure_ascii=False), flush=True)


def run(name, args):
    with (out / (name + '.txt')).open('wb') as log:
        result = subprocess.run([dart, *args], cwd=r / 'packages/info_storage', env=env,
                                stdout=log, stderr=subprocess.STDOUT, timeout=120)
    check(name, result.returncode == 0)
    text = (out / (name + '.txt')).read_text(encoding='utf-8', errors='replace'); start = text.find('{"status":')
    return json.loads(text[start:].strip()) if start >= 0 else None


class Peer:
    def __init__(self):
        log = (out / 'cli-stderr.txt').open('wb'); streams.append(log)
        self.p = subprocess.Popen([str(cli)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=log, text=True, encoding='utf-8', creationflags=subprocess.CREATE_NO_WINDOW)
        self.q = queue.Queue()

        def read():
            for line in self.p.stdout:
                self.q.put(line)
        threading.Thread(target=read, daemon=True).start()

    def call(self, command, **data):
        self.p.stdin.write(json.dumps(dict(command=command, **data)) + '\n'); self.p.stdin.flush()
        return json.loads(self.q.get(timeout=45))

    def close(self):
        self.p.stdin.close(); assert self.p.wait(timeout=10) == 0


def wait_until(test, timeout=600):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        assert process.poll() is None
        value = test()
        if value:
            return value
        time.sleep(.3)
    raise TimeoutError('Bounded actual UI observation missing')


def stop():
    result = subprocess.run([str(cli), 'app', 'quit', '--pid', str(process.pid)], capture_output=True,
                            text=True, encoding='utf-8', timeout=65, creationflags=subprocess.CREATE_NO_WINDOW)
    check('actual-normal-exit', result.returncode == 0 and json.loads(result.stdout)['status'] == 'exited'
          and process.wait(timeout=5) == 0, processId=process.pid)


try:
    for file, before in locks.items():
        file.write_bytes(before.replace(b'https://pub.dev', b'https://pub.flutter-io.cn'))
    run('format', ['format', 'test/support/packaged_recycle_ui_fixture.dart'])
    run('pub', ['pub', 'get', '--offline', '--enforce-lockfile'])
    run('analyze', ['analyze', '--fatal-infos'])
    run('prepare', ['run', 'test/support/packaged_recycle_ui_fixture.dart', 'prepare', str(temp)])
    expected = json.loads((temp / 'expected.json').read_text(encoding='utf-8'))
    with socket.socket() as available:
        available.bind(('127.0.0.1', 47125))
    child = env.copy(); child['LOCALAPPDATA'] = str(temp / 'profile')
    log = (out / 'app.txt').open('wb'); streams.append(log)
    process = subprocess.Popen([str(app)], cwd=app.parent, env=child,
                               stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
    peer = Peer()
    wait_until(lambda: peer.call('capabilities').get('status') == 'ok', 30)
    port = subprocess.run(['powershell', '-NoProfile', '-Command', 'Get-NetTCPConnection -LocalPort 47125 -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique'], capture_output=True, text=True, timeout=15)
    check('port-owned-by-child', port.stdout.strip() == str(process.pid), processId=process.pid)
    check('fresh-session', peer.call('session', chatLabel='最终包回收恢复虚构验收')['status'] == 'ok')
    check('fixture-recycled-not-catalogued', not peer.call('catalog')['items'])
    phase('restore-through-recycle-ui', pid=process.pid, root=str(temp), itemName='虚构回收验收简历')
    items = wait_until(lambda: peer.call('catalog').get('items'))
    check('restored-item-and-new-field', len(items) == 1 and items[0]['id'] == expected['itemId']
          and items[0]['fields'][0]['id'] != expected['oldFieldId'] and items[0]['fields'][0]['kind'] == 'file')
    item, field = items[0]['id'], items[0]['fields'][0]['id']
    denied = peer.call('file-fetch', requestId='synthetic-no-grant', itemId=item, fieldId=field, operationId='before-approval')
    check('restore-does-not-grant-access', denied['status'] != 'ok' and 'delivery' not in denied, status=denied['status'], errorCode=denied.get('errorCode'))
    request = peer.call('request', purpose='最终包回收恢复验收：只读取这份虚构普通文件。', fields=[dict(itemId=item, fieldId=field)])
    check('new-request-pending', request['status'] == 'pending')
    request_id = request['requestId']; phase('approve-restored-file', pid=process.pid, requestId=request_id)
    decision = wait_until(lambda: (v if (v := peer.call('status', requestId=request_id))['status'] != 'pending' else None))
    check('new-ui-approval', decision['status'] == 'approved')
    check('new-claim', peer.call('claim', requestId=request_id)['status'] == 'ok')
    delivery = peer.call('file-fetch', requestId=request_id, itemId=item, fieldId=field, operationId='restored-file')
    check('newly-approved-file-ready', delivery['status'] == 'ok' and delivery['delivery']['state'] == 'ready')
    copy = delivery['delivery']; path = Path(copy['path'])
    check('restored-original-bytes', path.read_bytes() == (temp / 'synthetic-resume.txt').read_bytes())
    release = peer.call('file-release', deliveryId=copy['deliveryId'])
    check('released-copy', release['status'] == 'ok' and release['delivery']['state'] == 'released' and not path.exists())
    phase('observe-delete-preview-only', pid=process.pid, itemName='虚构回收验收简历',
          itemId=item, receipt=str(out / 'preview-observed.json'))
    receipt = out / 'preview-observed.json'
    wait_until(receipt.is_file)
    check('delete-preview-observed-without-confirmation', json.loads(receipt.read_text(encoding='utf-8'))['observed'])
    check('item-still-present-no-ui-deletion', len(peer.call('catalog')['items']) == 1)
    stop()
    inspection = run('inspect', ['run', 'test/support/packaged_recycle_ui_fixture.dart', 'inspect', str(temp)])
    facts['inspection'] = inspection
    check('durable-ui-restore', inspection['information'] == 1 and inspection['itemIdentityPreserved']
          and inspection['fieldIdentityChanged'] and inspection['attachmentIdentityPreserved']
          and inspection['originalMatches'] and inspection['itemVersion'] == 3
          and inspection['availableRecycle'] == 0 and inspection['restoredRecycle'] == 1
          and inspection['deletionFacts'] == inspection['restoreFacts'] == inspection['deliveries'] == 1
          and inspection['noHeldCopies'] and inspection['activeGrants'] == 0)
    facts['restoreComplete'] = True
    phase('restore-complete-delete-deferred')
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
    facts['unexpectedLocks'] = bad
    facts['preservedTemporary'] = str(temp)
    (out / 'result.json').write_text(json.dumps(facts, indent=2) + '\n', encoding='utf-8')
    assert not bad, bad
