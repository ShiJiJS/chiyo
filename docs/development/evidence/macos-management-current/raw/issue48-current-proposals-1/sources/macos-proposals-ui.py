#!/usr/bin/env python3
"""Native Flutter + SQLCipher UI state checks with an independent AOT CLI.

UI actions, concurrent owner edits and the viewport are controlled. Screenshots are Flutter
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
    for name in ['apps/desktop/integration_test/macos_proposals_native_test.dart',
                 'scripts/qa/macos-proposals-ui.py',
                 'apps/desktop/lib/library.dart',
                 'apps/desktop/lib/import_proposals.dart',
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
                'integration_test/macos_proposals_native_test.dart', '-d', 'macos',
                f'--dart-define=MAC_QA_OWNER={owner}'], cwd=ROOT/'apps/desktop', stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        def locate():
            matches = re.findall(r'MAC_PROPOSALS_ROOT=([^\r\n]+)', log.read_text(errors='replace'))
            if not matches: return None
            p = Path(matches[-1])
            assert p.is_absolute() and not p.is_symlink() and p.name.startswith('aim-mac-proposals-ui-')
            assert (p/'.qa-owner').read_text() == owner
            return p.resolve()
        directory = wait_for(locate, timeout=600)
        command = None
        current_port = None
        batch = rejected = deletion = update = corrected = None
        first = first_field = second = second_field = None
        for index in range(1, 12):
            phase = wait_for(lambda: read_phase(index))
            name = phase['phase']; reply = {'ok': True}; checks = []
            if phase['port'] != current_port or name == 'repository-reopened':
                command = start_cli(phase['port']); current_port = phase['port']
            def checked(data, expected):
                value = command(data)
                assert value.get('status') == expected, (data['command'], value.get('status'))
                checks.append({'command':data['command'],'status':value['status']})
                return value
            if name == 'submit':
                checked({'command':'import-submit','items':[]},'invalid_request')
                value=checked({'command':'import-submit','agentName':'Mac QA','purpose':'Native batch review',
                    'items':[
                        {'name':'Mac first','description':'First public','fields':[{'name':'URL','description':'Entry','value':'first.native.example'}]},
                        {'name':'Mac second','description':'Second public','directoryId':'missing-native-directory','tagIds':['missing-native-tag'],
                         'fields':[{'name':'Note','description':'','value':'second native note','kind':'textNote'}]}
                    ]},'pending')
                batch=value['proposalId'];reply['proposalId']=batch
            elif name == 'draft-retained':
                checked({'command':'import-status','proposalId':batch},'pending')
                catalog=checked({'command':'catalog'},'ok')
                assert catalog['total']==0
                checks.append({'publicCatalogCount':0})
            elif name == 'confirmed':
                first, first_field, second, second_field = (phase[x] for x in ['firstId','firstField','secondId','secondField'])
                checked({'command':'import-status','proposalId':batch},'confirmed')
                catalog=checked({'command':'catalog'},'ok')
                assert catalog['total']==2
                text=json.dumps(catalog)
                for secret in ['first.native.example','reviewed.native.example','second native note']:
                    assert secret not in text
                checks.append({'publicCatalogCount':2,'noFieldValuesInCatalog':True})
            elif name == 'current-content':
                value=checked({'command':'import-submit','items':[{'name':'Rejected native','description':'','fields':[{'name':'Value','description':'','value':'do-not-retain-native'}]}]},'pending')
                rejected=value['proposalId'];reply['proposalId']=rejected
            elif name == 'rejected':
                checked({'command':'import-status','proposalId':rejected},'rejected')
                value=checked({'command':'delete-submit','itemId':first,'baseVersion':2},'pending')
                deletion=value['proposalId'];reply['proposalId']=deletion
            elif name == 'deleted':
                checked({'command':'delete-status','proposalId':deletion},'confirmed')
                value=checked({'command':'update-submit','update':{'itemId':second,'baseVersion':1,'changes':[{'operation':'correct','fieldId':second_field,'value':'submitted native conflict'}]}},'pending')
                update=value['proposalId'];reply['proposalId']=update
            elif name == 'conflict':
                checked({'command':'update-status','proposalId':update},'pending')
            elif name == 'conflict-rejected':
                checked({'command':'update-status','proposalId':update},'rejected')
                value=checked({'command':'update-submit','update':{'itemId':second,'baseVersion':2,'changes':[{'operation':'correct','fieldId':second_field,'value':'accepted native correction'}]}},'pending')
                corrected=value['proposalId'];reply['proposalId']=corrected
            elif name == 'corrected-update-confirmed':
                checked({'command':'update-status','proposalId':corrected},'confirmed')
                checked({'command':'read','requestId':corrected,'itemId':second,'fieldId':second_field},'unauthorized')
            elif name == 'repository-reopened':
                for kind, proposal in [('import',batch),('import',rejected),('delete',deletion),('update',update),('update',corrected)]:
                    checked({'command':kind+'-status','proposalId':proposal},'unauthorized')
                catalog=checked({'command':'catalog'},'ok')
                assert catalog['total']==1
                text=json.dumps(catalog)
                assert second in text and first not in text and 'accepted native correction' not in text
                checks.append({'publicCatalogCount':1,'remainingIdentityMatched':True,'noFieldValuesInCatalog':True})
            elif name == 'complete':
                result=json.loads((directory/'result.json').read_text()); assert result['complete']
                state['nativeResult']=result
            else: raise RuntimeError('Unexpected phase')
            state['phases'].append({'phase':name,'checks':checks})
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
                state['flutterProcessGroupRemaining']=False
            else:
                os.killpg(flutter.pid, signal.SIGTERM)
                state['forcedProcessGroupCleanup']=True;state['complete']=False
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
