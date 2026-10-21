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
    for name in ['apps/desktop/integration_test/macos_organization_native_test.dart',
                 'scripts/qa/macos-organization-ui.py',
                 'apps/desktop/lib/library.dart',
                 'apps/desktop/lib/organization_tasks.dart',
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
                'integration_test/macos_organization_native_test.dart', '-d', 'macos',
                f'--dart-define=MAC_QA_OWNER={owner}'], cwd=ROOT/'apps/desktop', stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        def locate():
            matches = re.findall(r'MAC_ORGANIZATION_ROOT=([^\r\n]+)', log.read_text(errors='replace'))
            if not matches: return None
            p = Path(matches[-1])
            assert p.is_absolute() and not p.is_symlink() and p.name.startswith('aim-mac-organization-ui-')
            assert (p/'.qa-owner').read_text() == owner
            return p.resolve()
        directory = wait_for(locate, timeout=600)
        command = other = None
        current_port = None
        first = first_field = second = second_field = excluded = excluded_field = None
        content = initial = conflict = revoke = reject = empty = reopening = None
        deadline = None
        for index in range(1, 13):
            phase = wait_for(lambda: read_phase(index))
            name = phase['phase']; reply = {'ok': True}; checks = []
            if phase['port'] != current_port or name == 'repository-reopened':
                command = start_cli(phase['port']); current_port = phase['port']
            def checked(data, expected, sender=None):
                value=(sender or command)(data)
                assert value.get('status') == expected, (data['command'],value.get('status'))
                checks.append({'command':data['command'],'status':value['status'],'session':'B' if sender else 'A'})
                return value
            def request(purpose, ids):
                return checked({'command':'organize-request','purpose':purpose,'itemIds':ids},'pending')['taskId']
            def metadata(task, status='ok', sender=None):
                return checked({'command':'organize-metadata','taskId':task},status,sender)
            def submit(task, changes, status):
                return checked({'command':'organize-submit','taskId':task,'changes':changes},status)
            def content_read(item, field, expected=None):
                result=checked({'command':'read','requestId':content,'itemId':item,'fieldId':field},'ok' if expected else 'unauthorized')
                if expected:
                    assert result.get('value')==expected
                    checks.append({'contentValueMatched':True})
            def change(item, version, folder='Mac organized', tags=None):
                return {'itemId':item,'baseVersion':version,'directoryName':folder,'tagNames':tags or ['Mac organized tag']}
            if name == 'request':
                first,first_field,second,second_field,excluded,excluded_field=(phase[x] for x in ['firstId','firstField','secondId','secondField','excludedId','excludedField'])
                content=checked({'command':'request','purpose':'Separate first field permission','fields':[{'itemId':first,'fieldId':first_field}]},'pending')['requestId']
                initial=request('Mac narrow classification',[first,second,excluded]);reply.update(taskId=initial,requestId=content)
                metadata(initial,'pending')
                other=start_cli(current_port)
                metadata(initial,'unauthorized',other)
            elif name == 'approved':
                status=checked({'command':'organize-status','taskId':initial},'active')
                assert status['itemCount']==2 and status['autoApply'] is True
                deadline=status['expiresAt']
                data=metadata(initial)
                assert {x['id'] for x in data['items']}=={first,second}
                assert all('fields' not in x for x in data['items'])
                text=json.dumps(data)
                for secret in ['private-first','private-second','private-excluded',first_field,second_field,excluded_field]:
                    assert secret not in text
                assert 'Fixture folder' in text and 'Fixture tag' in text
                checks.append({'metadataScopeCount':2,'fieldValuesAndIdentitiesAbsent':True})
                metadata(initial,'unauthorized',other)
                checked({'command':'status','requestId':content},'pending')
                checked({'command':'claim','requestId':content},'pending')
                content_read(first,first_field)
                submit(initial,[change(excluded,1,'Out of scope')],'invalid_proposal')
                submit(initial,[{**change(first,1),'value':'injected content'}],'invalid_request')
            elif name == 'content-approved':
                checked({'command':'claim','requestId':content},'ok')
                content_read(first,first_field,'private-first');content_read(second,second_field)
                result=submit(initial,[change(first,1),change(second,1)],'confirmed')
                assert result['expiresAt']==deadline
                checks.append({'organizationDeadlineUnchanged':True})
            elif name == 'completed':
                metadata(initial,'confirmed')
                submit(initial,[change(first,1)],'confirmed')
                content_read(first,first_field,'private-first');content_read(second,second_field)
                conflict=request('Mac atomic version conflict',[first,second]);reply['taskId']=conflict
            elif name == 'conflict':
                checked({'command':'organize-status','taskId':conflict},'active')
                submit(conflict,[change(first,2,'Must not create', ['Must not tag']),change(second,2,'Must not create', ['Must not tag'])],'organization_conflict')
                metadata(conflict,'conflicted')
                content_read(first,first_field,'private-first');content_read(second,second_field)
                revoke=request('Mac revoke active classification',[first]);reply['taskId']=revoke
            elif name == 'revoked':
                metadata(revoke,'cancelled');submit(revoke,[],'cancelled')
                content_read(first,first_field,'private-first')
                reject=request('Mac reject classification',[excluded]);reply['taskId']=reject
            elif name == 'rejected':
                metadata(reject,'rejected');submit(reject,[],'rejected')
                empty=request('Mac unchanged classification',[first]);reply['taskId']=empty
            elif name == 'empty-approved':
                metadata(empty)
                submit(empty,[],'confirmed')
                metadata(empty,'confirmed')
            elif name == 'empty-complete':
                reopening=request('Mac active task before repository reopen',[first]);reply['taskId']=reopening
            elif name == 'active-before-reopen':
                checked({'command':'organize-status','taskId':reopening},'active');metadata(reopening)
            elif name == 'repository-reopened':
                for task in [initial,conflict,revoke,reject,empty,reopening]:
                    metadata(task,'unauthorized')
                submit(reopening,[],'unauthorized');content_read(first,first_field)
                catalog=checked({'command':'catalog'},'ok')
                assert catalog['total']==3
                text=json.dumps(catalog)
                for secret in ['private-first','owner-corrected-second','private-excluded','Fixture folder','Mac organized tag']:
                    assert secret not in text
                checks.append({'publicCatalogCount':3,'noPrivateValuesOrClassificationNames':True})
            elif name == 'complete':
                result=json.loads((directory/'result.json').read_text());assert result['complete'];state['nativeResult']=result
            else: raise RuntimeError('Unexpected phase')
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
