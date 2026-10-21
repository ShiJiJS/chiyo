#!/usr/bin/env python3
"""Native Flutter + SQLCipher UI state checks with an independent AOT CLI.

Owner mutations and viewport/text scale are controlled. Screenshots are Flutter
render captures, not proof of physical panels, keyboard input or visible CUA.
"""
import argparse
import hashlib
import json
import os
import signal
from pathlib import Path
import queue
import re
import shutil
import subprocess
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--delivery', type=Path, required=True)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--states', action='store_true', help='Real UI revoke and natural one-minute expiry with persisted history')
    modes.add_argument('--large', action='store_true', help='502 history records and one 200-field scope')
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
             'cliSha256': entry['sha256'], 'phases': [], 'large': args.large, 'states': args.states}
    state['appBaseCommit'] = subprocess.check_output(
        ['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    state['worktreeStatus'] = subprocess.check_output(
        ['git', 'status', '--short'], cwd=ROOT, text=True).splitlines()
    sources = output / 'sources'
    sources.mkdir()
    state['qaSources'] = []
    for name in ['apps/desktop/integration_test/macos_removed_scope_native_test.dart',
                 'scripts/qa/macos-scope-ui.py',
                 'apps/desktop/lib/history.dart',
                 'apps/desktop/lib/main.dart',
                 'apps/desktop/integration_test/support/native_semantics_lifetime.dart']:
        source = ROOT / name
        shutil.copyfile(source, sources / source.name)
        state['qaSources'].append({'path': name,
            'sha256': hashlib.sha256(source.read_bytes()).hexdigest()})
    processes = []
    directory = None
    log = output / 'flutter.txt'
    def wait_for(predicate, timeout=300 if args.large or args.states else 120):
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
        with log.open('wb') as stream:
            flutter = subprocess.Popen([str(ROOT/'scripts/dev-macos.sh'), 'flutter', 'test', '--no-pub',
                'integration_test/macos_removed_scope_native_test.dart', '-d', 'macos',
                f'--dart-define=MAC_QA_OWNER={owner}',
                f'--dart-define=MAC_QA_LARGE={str(args.large).lower()}',
                f'--dart-define=MAC_QA_STATES={str(args.states).lower()}'], cwd=ROOT/'apps/desktop', stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        def locate():
            matches = re.findall(r'MAC_SCOPE_ROOT=([^\r\n]+)', log.read_text(errors='replace'))
            if not matches: return None
            p = Path(matches[-1])
            assert p.is_absolute() and not p.is_symlink() and p.name.startswith('aim-mac-scope-ui-')
            assert (p/'.qa-owner').read_text() == owner
            return p.resolve()
        directory = wait_for(locate, timeout=600)
        command = None
        current_port = None
        old_request = fresh_request = None
        item = old_field = remaining = fresh_field = None
        state_requests = {}
        for index in range(1, 17 if args.states else 12 if args.large else 10):
            phase = wait_for(lambda: read_phase(index))
            name = phase['phase']; reply = {'ok': True}; checks = []
            if phase['port'] != current_port:
                command = start_cli(phase['port']); current_port = phase['port']
            def read(field, request, expected=None):
                value = command({'command':'read','requestId':request,'itemId':item,'fieldId':field})
                if expected is None:
                    assert value['status'] == 'unauthorized', value.get('status')
                else:
                    assert value.get('value') == expected, value.get('status')
                checks.append({'field':field,'requestId':request,'status':value['status'],'expectedValueMatched':expected is not None})
            if name == 'request':
                item, old_field, remaining = phase['itemId'], phase['oldField'], phase['remainingField']
                requested = command({'command':'request','purpose':'移除字段与归档状态独立验证',
                    'fields':[{'itemId':item,'fieldId':f} for f in [old_field,remaining]]})
                assert requested['status'] == 'pending'
                old_request = requested['requestId']; reply['requestId'] = old_request
            elif name == 'approved':
                command({'command':'claim','requestId':old_request})
                read(old_field,old_request,'synthetic-private-address'); read(remaining,old_request,'synthetic-private-account')
            elif name in ['partial', 'restored', 'reapproved']:
                read(old_field,old_request); read(remaining,old_request,'synthetic-private-account')
                if name == 'restored':
                    fresh_field = phase['freshField']; assert fresh_field != old_field
                    read(fresh_field,old_request)
                    requested = command({'command':'request','purpose':'恢复字段重新申请',
                        'fields':[{'itemId':item,'fieldId':fresh_field}]})
                    assert requested['status']=='pending'
                    fresh_request=requested['requestId']; reply['requestId']=fresh_request
                elif name == 'reapproved':
                    command({'command':'claim','requestId':fresh_request})
                    read(fresh_field,fresh_request,'synthetic-private-address')
            elif name in ['all-removed','archived','repository-reopened','scale-reopened']:
                read(old_field,old_request); read(remaining,old_request); read(fresh_field,fresh_request)
            elif name == 'states-request':
                mode = phase['mode']
                request = command({'command':'request','purpose':f'历史状态验收 {mode}',
                    'fields':[{'itemId':phase['itemId'],'fieldId':phase['fieldId']}]})
                assert request['status'] == 'pending'
                state_requests[mode] = {'requestId':request['requestId'],'itemId':phase['itemId'],'fieldId':phase['fieldId']}
                reply['requestId'] = request['requestId']
                checks.append({'mode':mode,'command':'request','status':'pending'})
            elif name in ['states-approved','states-finished']:
                mode=phase['mode']; target=state_requests[mode]
                if name=='states-approved':
                    claimed=command({'command':'claim','requestId':target['requestId']}); assert claimed['status']=='ok'
                    checks.append({'mode':mode,'command':'claim','status':'ok'})
                if mode=='expired' and name=='states-finished':
                    started=time.monotonic(); time.sleep(62)
                    state['naturalExpiryWaitSeconds']=time.monotonic()-started
                value=command({'command':'read',**target})
                expected='ok' if name=='states-approved' else 'unauthorized'
                assert value['status']==expected,(mode,value['status'])
                if expected=='ok': assert value['value']==f'synthetic-private-{mode}'
                checks.append({'mode':mode,'command':'read','status':value['status']})
            elif name == 'states-reopened':
                for mode,target in state_requests.items():
                    value=command({'command':'read',**target}); assert value['status']=='unauthorized'
                    checks.append({'mode':mode,'command':'read','status':value['status']})
            elif name == 'large-approved':
                assert phase['fieldCount'] == phase['approvedCount'] == 200
                checks.append({'controlledNativeUiApprovalFields':200})
            elif name == 'complete':
                result=json.loads((directory/'result.json').read_text()); assert result['complete']
                state['nativeResult']=result
            else: raise RuntimeError('Unexpected phase')
            state['phases'].append({'phase':name,'checks':checks})
            # Atomic reply so the native reader never sees a partial JSON file.
            temp=directory/f'.reply-{index}.tmp'; temp.write_text(json.dumps(reply));temp.rename(directory/f'reply-{index}.json')
        exit_code=flutter.wait(timeout=45);state['flutterExitCode']=exit_code
        assert exit_code==0
        state['complete']=True
    except Exception as e:
        state['failure']={'type':type(e).__name__,'message':str(e)}
        raise
    finally:
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
        if 'flutter' in locals():
            try:
                os.killpg(flutter.pid, 0)
            except ProcessLookupError:
                state['flutterProcessGroupRemaining'] = False
            else:
                os.killpg(flutter.pid, signal.SIGTERM)
                state['forcedProcessGroupCleanup'] = True
                state['complete'] = False
        if directory:
            assert not directory.is_symlink() and (directory/'.qa-owner').read_text()==owner
            for p in directory.iterdir():
                if p.suffix=='.png' or p.name=='result.json':
                    shutil.copyfile(p, output/('native-'+p.name))
            if state['complete']: shutil.rmtree(directory)
            else: state['retainedOwnedRoot']=str(directory)
        (output/'result.json').write_text(json.dumps(state,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({'complete':state['complete'],'phases':len(state['phases'])}))


if __name__=='__main__': main()
