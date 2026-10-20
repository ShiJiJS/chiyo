#!/usr/bin/env python3
"""Native Flutter + SQLCipher UI state checks with an independent AOT CLI.

UI actions, concurrent owner edits and the viewport are controlled. Screenshots are Flutter
render captures, not proof of physical panels, keyboard input or visible CUA.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import queue
import re
import shutil
import subprocess
import threading
import time
import uuid
from macos_file_consumer import LocalFileConsumer

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--delivery', type=Path, required=True)
    parser.add_argument('--consume-files', action='store_true',
                        help='Upload synthetic managed copies using system curl to loopback HTTP')
    args = parser.parse_args()
    output = args.output.resolve(); output.relative_to(ROOT / 'build')
    output.mkdir(parents=True, exist_ok=False)
    delivery = args.delivery.resolve(strict=True)
    cli = delivery / 'cli/info'
    manifest = json.loads((delivery / 'manifest.json').read_text())
    entry = next(x for x in manifest['files'] if x['path'] == 'cli/info')
    assert hashlib.sha256(cli.read_bytes()).hexdigest() == entry['sha256']
    owner = uuid.uuid4().hex
    state = {'complete': False, 'productSource': manifest['sourceCommit'],
             'cliSha256': entry['sha256'], 'phases': []}
    state['appBaseCommit'] = subprocess.check_output(
        ['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    state['worktreeStatus'] = subprocess.check_output(
        ['git', 'status', '--short'], cwd=ROOT, text=True).splitlines()
    sources = output / 'sources'
    sources.mkdir()
    state['qaSources'] = []
    for name in ['apps/desktop/integration_test/macos_file_lifecycle_native_test.dart',
                 'scripts/qa/macos-file-lifecycle-ui.py',
                 'scripts/qa/macos_file_consumer.py',
                 'apps/desktop/lib/library.dart',
                 'apps/desktop/lib/revisions.dart',
                 'apps/desktop/lib/recycle.dart',
                 'apps/desktop/lib/history.dart',
                 'apps/desktop/lib/information_editor_draft.dart',
                 'apps/desktop/lib/information_files.dart',
                 'apps/desktop/lib/approvals.dart',
                 'apps/desktop/lib/proposal_queue.dart',
                 'apps/desktop/lib/proposal_workspace.dart',
                 'apps/desktop/lib/update_proposals.dart',
                 'apps/desktop/lib/information_editor.dart',
                 'apps/desktop/lib/main.dart',
                 'apps/desktop/integration_test/support/native_semantics_lifetime.dart']:
        source = ROOT / name
        shutil.copyfile(source, sources / source.name)
        state['qaSources'].append({'path': name,
            'sha256': hashlib.sha256(source.read_bytes()).hexdigest()})
    processes = []
    directory = None
    consumer = None
    log = output / 'flutter.txt'
    def wait_for(predicate, timeout=120):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = predicate()
            if value: return value
            if flutter.poll() is not None:
                raise RuntimeError('Flutter exited before expected evidence')
            time.sleep(.02)
        raise TimeoutError('Native UI driver deadline')
    def start_cli(port):
        errors = (output / f'cli-{len(processes)}-stderr.txt').open('wb')
        p = subprocess.Popen([str(cli), '--port', str(port)], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=errors)
        q = queue.Queue()
        def reader():
            for line in p.stdout: q.put(json.loads(line))
        threading.Thread(target=reader, daemon=True).start()
        processes.append((p, errors))
        def command(value):
            p.stdin.write(json.dumps(value).encode() + b'\n'); p.stdin.flush()
            return q.get(timeout=15)
        command({'command':'session','chatLabel':'Mac 合成独立 CLI'})
        return command
    def read_phase(index):
        try: return json.loads((directory / f'phase-{index}.json').read_text())
        except (FileNotFoundError, json.JSONDecodeError): return None
    try:
        if args.consume_files:
            consumer = LocalFileConsumer(output)
        with log.open('wb') as stream:
            flutter = subprocess.Popen([str(ROOT/'scripts/dev-macos.sh'), 'flutter', 'test', '--no-pub',
                'integration_test/macos_file_lifecycle_native_test.dart', '-d', 'macos',
                f'--dart-define=MAC_QA_OWNER={owner}'], cwd=ROOT/'apps/desktop', stdout=stream, stderr=subprocess.STDOUT)
        def locate():
            matches = re.findall(r'MAC_FILE_LIFECYCLE_ROOT=([^\r\n]+)', log.read_text(errors='replace'))
            if not matches: return None
            p = Path(matches[-1])
            assert p.is_absolute() and not p.is_symlink() and p.name.startswith('aim-mac-file-lifecycle-ui-')
            assert (p/'.qa-owner').read_text() == owner
            return p.resolve()
        directory = wait_for(locate, timeout=600)
        command = other = None
        current_port = None
        item = old_file = old_text = fresh_file = fresh_text = request_id = fresh_request = expiry_request = reopened_request = None
        originals = {1: bytes((i * 37 + 11) % 256 for i in range(1024)),
                     2: bytes((i * 13 + 3) % 256 for i in range(2049))}
        deliveries = {}
        deadline = None
        for index in range(1, 18):
            phase = wait_for(lambda: read_phase(index))
            name = phase['phase']; reply = {'ok': True}; checks = []
            print('FILE_LIFECYCLE_PHASE=' + name, flush=True)
            if phase['port'] != current_port or name == 'reopened':
                command = start_cli(phase['port']); current_port = phase['port']
            def checked(data, expected='ok', sender=None):
                value=(sender or command)(data)
                assert value.get('status') == expected, (name, data['command'], value)
                checks.append({'command':data['command'],'status':value['status'],'session':'B' if sender else 'A'})
                return value
            def fetch(op, version=1, request=None, field=None, denied=False, sender=None):
                data={'command':'file-fetch','requestId':request or request_id,'itemId':item,
                      'fieldId':field or old_file,'operationId':op}
                value=checked(data,'unauthorized' if denied else 'ok',sender)
                if denied:
                    assert 'delivery' not in value
                    return
                copy=value['delivery']; path=Path(copy['path'])
                assert copy['attachmentVersion']==version and copy['byteLength']==len(originals[version])
                assert path.read_bytes()==originals[version]
                if op in deliveries:
                    assert copy['deliveryId']==deliveries[op]['deliveryId'] and copy['path']==deliveries[op]['path']
                else:
                    assert copy['deliveryId'] not in {d['deliveryId'] for d in deliveries.values()}
                    deliveries[op]=copy
                    if consumer: checks.append(consumer.consume(path,originals[version],op))
                checks.append({'operation':op,'attachmentVersion':version,'bytesMatched':True})
                return copy
            def absent(ops):
                for op in ops:
                    path=Path(deliveries[op]['path'])
                    assert not path.exists(),op
                    fact=checked({'command':'file-status','deliveryId':deliveries[op]['deliveryId']})['delivery']
                    assert fact['state']=='expired' and 'path' not in fact, fact
                    checks.append({'operation':op,'state':fact['state'],'reason':fact.get('reason'), 'copyAbsent':True})
                    if consumer: checks.append(consumer.verify_released(path,op+'-invalidated'))
            def request(fields):
                return checked({'command':'request','purpose':'Mac file lifecycle',
                    'fields':[{'itemId':item,'fieldId':f} for f in fields]},'pending')['requestId']
            def no_text(grant, field):
                checked({'command':'read','requestId':grant,'itemId':item,'fieldId':field},'unauthorized')
            if name=='request':
                item,old_file,old_text=(phase[x] for x in ['itemId','fileId','textId'])
                request_id=request([old_file,old_text]);reply['requestId']=request_id
                fetch('before-approval',denied=True);other=start_cli(current_port)
            elif name=='approved':
                deadline=checked({'command':'claim','requestId':request_id})['expiresAt']
                fetch('original-v1');no_text(request_id,old_text)
                fetch('cross-chat',denied=True,sender=other)
            elif name=='cancelled':
                fetch('original-v1')
                assert checked({'command':'claim','requestId':request_id})['expiresAt']==deadline
            elif name=='replaced':
                fetch('new-v2',2);fetch('original-v1')
                assert checked({'command':'claim','requestId':request_id})['expiresAt']==deadline
                checks.append({'fixedGrantExpiry':True,'oldAndNewBytesDifferent':originals[1]!=originals[2]})
            elif name=='revision-cancelled':
                fetch('new-v2',2);fetch('original-v1')
            elif name=='revision-restored':
                fetch('restored-v1');fetch('new-v2',2);fetch('original-v1')
                assert checked({'command':'claim','requestId':request_id})['expiresAt']==deadline
            elif name=='delete-cancelled':
                fetch('restored-v1');fetch('new-v2',2)
            elif name=='deleted':
                fetch('after-delete',denied=True);fetch('original-v1',denied=True)
                absent(['original-v1','new-v2','restored-v1'])
                assert checked({'command':'catalog'})['total']==0
            elif name=='restored':
                fresh_file,fresh_text=phase['fileId'],phase['textId']
                assert fresh_file!=old_file and fresh_text!=old_text
                fetch('restored-old-id',denied=True)
                fetch('restored-new-id',field=fresh_file,denied=True)
                fresh_request=request([fresh_file,fresh_text]);reply['requestId']=fresh_request
            elif name in ['reapproved','revoke-cancelled']:
                fetch('recycled-v1',request=fresh_request,field=fresh_file)
                no_text(fresh_request,fresh_text)
            elif name=='revoked':
                fetch('after-revoke',request=fresh_request,field=fresh_file,denied=True)
                absent(['recycled-v1'])
                expiry_request=request([fresh_file]);reply['requestId']=expiry_request
            elif name=='expiry-approved':
                claim=checked({'command':'claim','requestId':expiry_request})
                expires_at=datetime.fromisoformat(claim['expiresAt'].replace('Z','+00:00'))
                fetch('expires-v1',request=expiry_request,field=fresh_file)
                start=time.monotonic();maximum=start+75
                while datetime.now(timezone.utc)<=expires_at:
                    assert time.monotonic()<maximum and flutter.poll() is None
                    time.sleep(.1)
                fetch('after-expiry',request=expiry_request,field=fresh_file,denied=True)
                checks.append({'realExpiryWaitSeconds':time.monotonic()-start,'expiresAt':claim['expiresAt'],
                               'clockInjected':False})
            elif name=='expired':
                absent(['expires-v1'])
                fetch('expired-original-op',request=expiry_request,field=fresh_file,denied=True)
            elif name=='reopened':
                fetch('old-after-reopen',request=fresh_request,field=fresh_file,denied=True)
                no_text(request_id,old_text)
                reopened_request=request([fresh_file]);reply['requestId']=reopened_request
            elif name=='reopen-approved':
                copy=fetch('fresh-after-reopen',request=reopened_request,field=fresh_file)
                released=checked({'command':'file-release','deliveryId':copy['deliveryId']})['delivery']
                assert released['state']=='released' and not Path(copy['path']).exists()
                no_text(reopened_request,fresh_text)
                if consumer: checks.append(consumer.verify_released(Path(copy['path']),'fresh-after-reopen'))
            elif name=='complete':
                result=json.loads((directory/'result.json').read_text());assert result['complete']
                state['nativeResult']=result;state['distinctFileDeliveries']=len(deliveries)
            else: raise RuntimeError('Unexpected phase '+name)
            state['phases'].append({'phase':name,'checks':checks})
            temp=directory/f'.reply-{index}.tmp';temp.write_text(json.dumps(reply));temp.rename(directory/f'reply-{index}.json')
        state['flutterExitCode']=flutter.wait(timeout=45)
        assert state['flutterExitCode']==0
        state['complete']=True
    except Exception as e:
        state['failure']={'type':type(e).__name__,'message':str(e)}
        raise
    finally:
        if consumer:
            try:
                state['fileConsumer'] = consumer.close()
            except Exception as e:
                state['complete'] = False
                state['consumerCleanupFailure'] = {'type': type(e).__name__, 'message': str(e)}
        for p, errors in processes:
            p.stdin.close()
            try: code=p.wait(timeout=10)
            except subprocess.TimeoutExpired:
                p.terminate(); code=p.wait(timeout=10)
                state['complete']=False
            errors.close()
            state.setdefault('cliExits',[]).append(code)
            if code != 0: state['complete']=False
        if 'flutter' in locals() and flutter.poll() is None:
            flutter.terminate(); flutter.wait(timeout=15)
            state['forcedFailedRunCleanup']=True;state['complete']=False
        if directory:
            assert not directory.is_symlink() and (directory/'.qa-owner').read_text()==owner
            for p in directory.iterdir():
                if p.suffix=='.png' or p.name=='result.json':
                    shutil.copyfile(p, output/('native-'+p.name))
            if state['complete']: shutil.rmtree(directory)
            else: state['retainedOwnedRoot']=str(directory)
        (output/'result.json').write_text(json.dumps(state,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({'complete':state['complete'],'phases':len(state['phases'])}))
    if not state['complete']: raise SystemExit(1)


if __name__=='__main__': main()
