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
    for name in ['apps/desktop/integration_test/macos_credential_management_native_test.dart',
                 'scripts/qa/macos-credential-management-ui.py',
                 'apps/desktop/lib/credentials.dart',
                 'apps/desktop/lib/credential_management.dart',
                 'apps/desktop/lib/credential_dialogs.dart',
                 'apps/desktop/lib/information_workspace.dart',
                 'apps/desktop/lib/library.dart',
                 'apps/desktop/lib/main.dart',
                 'apps/desktop/integration_test/support/native_semantics_lifetime.dart']:
        source = ROOT / name
        shutil.copyfile(source, sources / source.name)
        state['qaSources'].append({'path': name,
            'sha256': hashlib.sha256(source.read_bytes()).hexdigest()})
    processes = []
    directory = None
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
        with log.open('wb') as stream:
            flutter = subprocess.Popen([str(ROOT/'scripts/dev-macos.sh'), 'flutter', 'test', '--no-pub',
                'integration_test/macos_credential_management_native_test.dart', '-d', 'macos',
                f'--dart-define=MAC_QA_OWNER={owner}'], cwd=ROOT/'apps/desktop', stdout=stream, stderr=subprocess.STDOUT)
        def locate():
            matches = re.findall(r'MAC_CREDENTIAL_MANAGEMENT_ROOT=([^\r\n]+)', log.read_text(errors='replace'))
            if not matches: return None
            p = Path(matches[-1])
            assert p.is_absolute() and not p.is_symlink() and p.name.startswith('aim-mac-credential-management-ui-')
            assert (p/'.qa-owner').read_text() == owner
            return p.resolve()
        directory = wait_for(locate, timeout=600)
        command = None
        current_port = None
        expectations={
            '01-created-hidden':(1,False,'available'),
            '02-linked-hidden':(1,False,'available'),
            '03-public':(1,True,'available'),
            '04-rotated':(2,True,'available'),
            '05-disabled':(2,True,'disabled'),
            '06-enabled':(2,True,'available'),
            '07-version-restored':(3,True,'disabled'),
            '08-version-enabled':(3,True,'available'),
            '09-deleted':(3,False,'deleted'),
            '10-recycle-restored':(4,True,'disabled'),
            '11-recycle-enabled':(4,True,'available'),
            '12-expired':(4,True,'expired'),
            '13-hidden':(4,False,'available'),
            '14-reopened':(4,False,'available'),
        }
        for index in range(1,16):
            phase=wait_for(lambda:read_phase(index))
            name=phase['phase'];reply={'ok':True};checks=[]
            if phase['port'] != current_port or name=='14-reopened':
                command=start_cli(phase['port']);current_port=phase['port']
            def checked(data,expected):
                value=command(data)
                assert value.get('status')==expected,(data['command'],value.get('status'),value.get('errorCode'))
                encoded=json.dumps(value)
                for secret in ['synthetic-native-secret-one','synthetic-native-secret-two','private-native-credential-note','private-linked-value']:
                    assert secret not in encoded,'Private fixture content leaked'
                checks.append({'command':data['command'],'status':value['status'],'privateFixtureContentAbsent':True})
                return value
            if name=='complete':
                result=json.loads((directory/'result.json').read_text());assert result['complete'];state['nativeResult']=result
            else:
                version,visible,availability=expectations[name]
                credential=phase['credentialId']
                assert phase['version']==version and phase['catalogVisible']==visible and phase['availability']==availability
                entries=checked({'command':'credential-catalog'},'ok')['credentials']
                assert len(entries)==int(visible)
                if visible:
                    assert entries[0]=={'credentialId':credential,'name':'Mac reviewed token','publicPurpose':'Synthetic public token purpose','form':'string','version':version,'availability':availability}
                checks.append({'catalogCount':len(entries),'expectedVersion':version,'expectedAvailability':availability})
                catalog=checked({'command':'catalog'},'ok')
                assert catalog['total']==1
                checked({'command':'read','requestId':credential,'itemId':phase['itemId'],'fieldId':phase['fieldId']},'unauthorized')
                # Only deliberately ineligible requests; no executable inspection,
                # credential grant, secret injection, or process start is claimed.
                code=None;requested_version=version
                if availability!='available':code='credential_'+availability
                elif not visible:code='invalid_reference'
                elif version>1:code='credential_version_changed';requested_version=version-1
                if code:
                    expected='revoked' if availability in ['disabled','deleted'] else 'expired' if availability=='expired' else 'conflict' if code=='credential_version_changed' else 'invalid_request'
                    denied=checked({'command':'request-use','protocolVersion':2,'purpose':'Synthetic ineligible management probe','credentials':[{'alias':'token','credentialId':credential,'version':requested_version}],
                        'launch':{'receiver':'gh_token','executable':'/usr/bin/false','argv':['repo','view','synthetic/project'],'cwd':'/tmp','env':{'GH_TOKEN':{'secret':'token'}}}},expected)
                    assert denied['errorCode']==code and denied.get('operationClaimed') is False
                    checks.append({'eligibilityError':code,'operationClaimed':False})
            state['phases'].append({'phase':name,'checks':checks})
            temp=directory/f'.reply-{index}.tmp';temp.write_text(json.dumps(reply));temp.rename(directory/f'reply-{index}.json')
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
