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
    for name in ['apps/desktop/integration_test/macos_attachment_preserve_native_test.dart',
                 'scripts/qa/macos-attachment-preserve-ui.py',
                 'scripts/qa/macos_file_consumer.py',
                 'apps/desktop/lib/library.dart',
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
                'integration_test/macos_attachment_preserve_native_test.dart', '-d', 'macos',
                f'--dart-define=MAC_QA_OWNER={owner}'], cwd=ROOT/'apps/desktop', stdout=stream, stderr=subprocess.STDOUT)
        def locate():
            matches = re.findall(r'MAC_ATTACHMENT_PRESERVE_ROOT=([^\r\n]+)', log.read_text(errors='replace'))
            if not matches: return None
            p = Path(matches[-1])
            assert p.is_absolute() and not p.is_symlink() and p.name.startswith('aim-mac-attachment-preserve-ui-')
            assert (p/'.qa-owner').read_text() == owner
            return p.resolve()
        directory = wait_for(locate, timeout=600)
        command = other = None
        current_port = None
        item = text_field = file_field = request_id = fresh = fresh_request = reopened_request = update = None
        original = bytes((i * 37 + 11) % 256 for i in range(1024))
        deadline = None
        delivered_ids = set()
        for index in range(1, 11):
            phase = wait_for(lambda: read_phase(index))
            name = phase['phase']; reply = {'ok': True}; checks = []
            if phase['port'] != current_port or name == 'reopened':
                command = start_cli(phase['port']); current_port = phase['port']
            def checked(data, expected, sender=None):
                value=(sender or command)(data)
                assert value.get('status') == expected, (data['command'],value.get('status'),value.get('errorCode'))
                checks.append({'command':data['command'],'status':value['status'],'session':'B' if sender else 'A'})
                return value
            def read(field, expected=None, request=None):
                value=checked({'command':'read','requestId':request or request_id,'itemId':item,'fieldId':field},'ok' if expected else 'unauthorized')
                if expected:
                    assert value['value']==expected
                    checks.append({'textValueMatched':True})
            def fetch(op, request=None, status='ok', sender=None):
                data={'command':'file-fetch','requestId':request or request_id,'itemId':item,'fieldId':file_field,'operationId':op}
                value=checked(data,status,sender)
                if status != 'ok':
                    assert value.get('operationClaimed') is False
                    return
                copy=value['delivery'];path=Path(copy['path'])
                assert path.read_bytes()==original
                assert copy['attachmentVersion']==1 and copy['byteLength']==len(original)
                assert copy['deliveryId'] not in delivered_ids
                delivered_ids.add(copy['deliveryId'])
                retry=checked(data,'ok')['delivery']
                assert retry['deliveryId']==copy['deliveryId'] and retry['path']==str(path)
                if consumer:
                    checks.append(consumer.consume(path, original, op))
                released=checked({'command':'file-release','deliveryId':copy['deliveryId']},'ok')['delivery']
                assert released['state']=='released' and not path.exists()
                if consumer:
                    checks.append(consumer.verify_released(path, op))
                checks.append({'attachmentBytesMatched':1024,'attachmentVersion':1,'repeatSameDelivery':True,'releasedPathAbsent':True})
            def new_request(fields):
                return checked({'command':'request','purpose':'Mac mixed file preservation','fields':[{'itemId':item,'fieldId':f} for f in fields]},'pending')['requestId']
            if name == 'request':
                item,text_field,file_field=(phase[x] for x in ['itemId','textId','fileId'])
                request_id=new_request([text_field,file_field]);reply['requestId']=request_id
                fetch('before-approval',status='unauthorized')
                other=start_cli(current_port)
            elif name == 'approved':
                deadline=checked({'command':'claim','requestId':request_id},'ok')['expiresAt']
                read(text_field,'before native edit')
                fetch('initial')
                fetch('different-session',status='unauthorized',sender=other)
            elif name == 'edited':
                read(text_field,'edited native text');fetch('after-edit')
                value=checked({'command':'update-submit','update':{'itemId':item,'baseVersion':2,'changes':[{'operation':'correct','fieldId':text_field,'value':'proposed native text'}]}},'pending')
                update=value['proposalId'];reply['proposalId']=update
            elif name == 'proposal-confirmed':
                checked({'command':'update-status','proposalId':update},'confirmed')
                read(text_field,'proposed native text');fetch('after-proposal')
                read(text_field,request=update)
            elif name == 'text-removed':
                read(text_field);fetch('after-text-removal')
            elif name == 'text-restored':
                fresh=phase['freshId'];assert fresh!=text_field
                read(text_field);read(fresh);fetch('after-text-restore')
                fresh_request=new_request([fresh]);reply['requestId']=fresh_request
            elif name == 'reapproved':
                checked({'command':'claim','requestId':fresh_request},'ok')
                read(fresh,'proposed native text',fresh_request);read(text_field)
                assert checked({'command':'claim','requestId':request_id},'ok')['expiresAt']==deadline
                checks.append({'originalGrantDeadlineUnchanged':True})
            elif name == 'reopened':
                read(text_field);read(fresh,request=fresh_request)
                fetch('old-after-reopen',status='unauthorized')
                checked({'command':'update-status','proposalId':update},'unauthorized')
                catalog=checked({'command':'catalog'},'ok')
                assert catalog['total']==1 and 'proposed native text' not in json.dumps(catalog)
                reopened_request=new_request([file_field]);reply['requestId']=reopened_request
            elif name == 'reopen-approved':
                checked({'command':'claim','requestId':reopened_request},'ok')
                fetch('fresh-after-reopen',reopened_request)
                read(fresh,request=reopened_request)
            elif name == 'complete':
                result=json.loads((directory/'result.json').read_text());assert result['complete'];state['nativeResult']=result
                state['distinctFileDeliveries']=len(delivered_ids)
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
