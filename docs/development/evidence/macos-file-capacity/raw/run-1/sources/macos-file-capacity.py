#!/usr/bin/env python3
"""Native Flutter + SQLCipher UI state checks with an independent AOT CLI.

UI actions, concurrent owner edits and the viewport are controlled. Screenshots are Flutter
render captures, not proof of physical panels, keyboard input or visible CUA.
"""
import argparse
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
    for name in ['apps/desktop/integration_test/macos_file_capacity_native_test.dart',
                 'scripts/qa/macos-file-capacity.py', 'scripts/qa/macos_file_consumer.py',
                 'apps/desktop/lib/information_attachment_capacity.dart',
                 'packages/info_core/lib/information_file_access.dart',
                 'packages/info_core/lib/information_delivery_access.dart',
                 'packages/info_core/lib/information_files.dart',
                 'packages/info_core/lib/information_delivery_models.dart',
                 'packages/info_storage/lib/information_attachments_storage.dart',
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
            return q.get(timeout=30)
        command({'command':'session','chatLabel':'Mac 合成独立 CLI'})
        return command
    def read_phase(index):
        try: return json.loads((directory / f'phase-{index}.json').read_text())
        except (FileNotFoundError, json.JSONDecodeError): return None
    try:
        consumer = LocalFileConsumer(output, maximum_bytes=10 * 1024 * 1024)
        with log.open('wb') as stream:
            flutter = subprocess.Popen([str(ROOT/'scripts/dev-macos.sh'), 'flutter', 'test', '--no-pub',
                'integration_test/macos_file_capacity_native_test.dart', '-d', 'macos',
                f'--dart-define=MAC_QA_OWNER={owner}'], cwd=ROOT/'apps/desktop', stdout=stream, stderr=subprocess.STDOUT)
        def locate():
            matches = re.findall(r'MAC_FILE_CAPACITY_ROOT=([^\r\n]+)', log.read_text(errors='replace'))
            if not matches: return None
            p = Path(matches[-1])
            assert p.is_absolute() and not p.is_symlink() and p.name.startswith('aim-mac-file-capacity-')
            assert (p/'.qa-owner').read_text() == owner
            return p.resolve()
        directory = wait_for(locate, timeout=600)
        commands = None
        requests = []
        current_port = None
        originals = {'large': bytes((i * 37 + 11) % 256 for i in range(256)) * (10 * 1024 * 1024 // 256), 'empty': b''}
        fields = {}
        deliveries = {}
        for index in range(1, 9):
            phase = wait_for(lambda: read_phase(index), timeout=180)
            name = phase['phase']; reply = {'ok': True}; checks = []
            print('FILE_CAPACITY_PHASE=' + name, flush=True)
            if phase['port'] != current_port:
                commands = [start_cli(phase['port']) for _ in range(2)]
                current_port = phase['port']
            def checked(data, expected='ok', sender=0):
                value = commands[sender](data)
                assert value.get('status') == expected, (name, data['command'], value)
                checks.append({'command':data['command'], 'status':value['status'], 'session':sender})
                return value
            def fetch(op, kind, sender=0, denied=False):
                item, field = fields[kind]
                value = checked({'command':'file-fetch', 'requestId':requests[sender],
                    'itemId':item, 'fieldId':field, 'operationId':op},
                    'service_unavailable' if denied else 'ok', sender)
                if denied:
                    assert value['errorCode']=='delivery_capacity' and value['operationClaimed'] is False
                    assert 'delivery' not in value and 'deliveryId' not in value
                    checks.append({'operation':op,'capacityRejectedWithoutClaim':True})
                    return
                copy = value['delivery']; path=Path(copy['path'])
                assert copy['byteLength']==len(originals[kind]) and path.read_bytes()==originals[kind]
                key=(sender,op)
                if key in deliveries:
                    assert deliveries[key]['deliveryId']==copy['deliveryId'] and deliveries[key]['path']==copy['path']
                else:
                    assert copy['deliveryId'] not in {d['deliveryId'] for d in deliveries.values()}
                    deliveries[key] = dict(copy, sender=sender, kind=kind, operation=op)
                checks.append({'operation':op, 'kind':kind, 'byteLength':len(originals[kind]),
                    'sha256':hashlib.sha256(originals[kind]).hexdigest(), 'bytesExactlyMatched':True})
                return deliveries[key]
            def release(copy):
                value = checked({'command':'file-release','deliveryId':copy['deliveryId']}, sender=copy['sender'])
                assert value['delivery']['state']=='released' and not Path(copy['path']).exists()
                fact = checked({'command':'file-status','deliveryId':copy['deliveryId']}, sender=copy['sender'])['delivery']
                assert fact['state']=='released' and 'path' not in fact
                copy['released']=True
            if name=='request':
                fields = {'large':(phase['largeItem'],phase['largeField']), 'empty':(phase['emptyItem'],phase['emptyField'])}
                for sender in range(2):
                    value=checked({'command':'request','purpose':'Synthetic Mac capacity',
                        'fields':[{'itemId':item,'fieldId':field} for item,field in fields.values()]}, 'pending', sender)
                    requests.append(value['requestId'])
                reply['requests']=requests
            elif name=='approved':
                for sender in range(2): checked({'command':'claim','requestId':requests[sender]},sender=sender)
                for i in range(10): fetch('large-'+str(i),'large')
                copy=fetch('large-0','large')  # Re-query succeeds even at the byte limit.
                checks.append(consumer.consume(Path(copy['path']), originals['large'], 'maximum-file'))
                fetch('bytes-overflow','large',sender=1,denied=True)
            elif name=='byte-full':
                release(deliveries[(0,'large-0')])
                checks.append(consumer.verify_released(Path(deliveries[(0,'large-0')]['path']),'maximum-file'))
                fetch('bytes-overflow','large',sender=1) # Same previously rejected operation, no stale reservation.
                fetch('bytes-overflow','large',sender=1)
                fetch('bytes-overflow-again','large',sender=0,denied=True)
            elif name=='byte-retried':
                for copy in deliveries.values():
                    if not copy.get('released'): release(copy)
            elif name=='byte-released':
                for i in range(31): fetch('empty-'+str(i),'empty')
                copy=fetch('empty-last','empty',sender=1)
                checks.append(consumer.consume(Path(copy['path']), b'', 'empty-file'))
                fetch('empty-0','empty')  # Idempotent re-query doesn't consume a 33rd slot.
                fetch('count-overflow','empty',denied=True)
                fetch('count-overflow-b','empty',sender=1,denied=True)
            elif name=='count-full':
                release(deliveries[(1,'empty-last')])
                checks.append(consumer.verify_released(Path(deliveries[(1,'empty-last')]['path']),'empty-file'))
                fetch('count-overflow','empty')
                fetch('count-overflow','empty')
                fetch('count-overflow-b','empty',sender=1,denied=True)
            elif name=='count-retried':
                for copy in deliveries.values():
                    if not copy.get('released'): release(copy)
            elif name=='complete':
                result=json.loads((directory/'result.json').read_text()); assert result['complete']
                assert len(deliveries)==44 and all(d.get('released') for d in deliveries.values())
                assert result['deliveryHistoryCount']==44
                # New CLI connections after same-process encrypted library reopen cannot reuse old approval.
                item,field=fields['large']
                checked({'command':'file-fetch','requestId':requests[0], 'itemId':item,
                         'fieldId':field,'operationId':'old-after-reopen'}, 'unauthorized')
                state['nativeResult']=result; state['distinctFileDeliveries']=len(deliveries)
            else: raise RuntimeError('Unexpected phase '+name)
            state['phases'].append({'phase':name, 'checks':checks})
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
            flutter.terminate(); flutter.wait(timeout=30)
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
