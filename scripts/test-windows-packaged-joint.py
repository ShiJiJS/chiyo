"""Verify an existing Windows package with disposable synthetic data only.

Requires the repository SDK dependencies and the native info-focus-fixture.exe
CMake test target. The receiver is a synthetic masked control, not a real login.
The test needs port 47125 free; it never exits another installation or opens the
real user library. Its own application processes exit through `app quit --pid`.

An operator must follow printed phases, approve both dummy uses in the actual UI,
focus the receiver's first empty masked field for discovery and again after
approval, then write the indicated JSON receipt with {"observed": true}. The
helper privately seeds both random dummy credentials and a dummy backup key;
never read, print, photograph or attach those raw secrets. Export the indicated
format9 backup in the actual app using its native Save dialog, then choose backup
and key in the fresh empty app's two native Open dialogs, inspect preview and
confirm restore. Only after actual UI observations write the indicated export
and restore receipts. A receipt is an operator observation, not image recognition.

Commands use a random invalid GH_TOKEN with real `gh api` read-only GET requests;
HTTP401 is expected and does not prove successful real account authentication.
Only metadata and boolean content comparisons are logged. Any failed run is kept;
its temporary root is preserved for diagnosis if shutdown succeeded. There is no
force-kill fallback. On success the owned temporary root is removed after all
processes have closed and symlinks/junctions are rejected.
"""
from pathlib import Path
import argparse,os,sys,json,subprocess,tempfile,time,socket,hashlib,shutil,queue,threading,base64
sys.stdout.reconfigure(encoding='utf-8')
parser=argparse.ArgumentParser(description='Operator-assisted synthetic packaged command/fill/format9 joint acceptance. Read the script docstring first.')
for name in ['delivery','receiver','gh','dart','evidence']:parser.add_argument('--'+name,type=Path,required=True)
a=parser.parse_args()
if sys.platform!='win32':parser.error('This acceptance requires Windows')
r=Path(__file__).resolve().parent.parent;out=a.evidence.resolve();out.mkdir(parents=True,exist_ok=False)
payload=a.delivery.resolve(strict=True);app=payload/'app/info_desktop.exe';cli=payload/'cli/info.exe'
receiver=a.receiver.resolve(strict=True);gh=a.gh.resolve(strict=True);dart=str(a.dart.resolve(strict=True))
manifest=json.loads((payload/'manifest.json').read_text(encoding='utf-8-sig'))
for entry in manifest['files']:
    p=(payload/entry['path']).resolve(strict=True);assert p.is_relative_to(payload.resolve()) and hashlib.sha256(p.read_bytes()).hexdigest()==entry['sha256'] and p.stat().st_size==entry['bytes']
temp=Path(tempfile.mkdtemp(prefix='aim-packaged-joint-')).resolve();env=os.environ.copy();env.update(PUB_HOSTED_URL='https://pub.flutter-io.cn',FLUTTER_STORAGE_BASE_URL='https://storage.flutter-io.cn')
locks={r/p/'pubspec.lock':(r/p/'pubspec.lock').read_bytes() for p in ['packages/info_core','packages/info_cli','packages/info_storage','apps/desktop']};norm=lambda b:b.replace(b'https://pub.flutter-io.cn',b'https://pub.dev').replace(b'\r\n',b'\n')
facts=dict(productSource=manifest['sourceCommit'],checks=[],complete=False);handles=[];process=None;helper=None;agent=None
def record(name,condition,**data):
    facts['checks'].append(dict(check=name,passed=bool(condition),**data));assert condition,name
def phase(name,**data):
    p=dict(phase=name,**data);(out/'phase.json').write_text(json.dumps(p,indent=2),encoding='utf-8');print(json.dumps(p),flush=True)
class Peer:
    def __init__(self,cmd,cwd,name,environment=None):
        log=(out/(name+'-stderr.txt')).open('wb');handles.append(log)
        self.process=subprocess.Popen(cmd,cwd=cwd,env=environment,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log,text=True,encoding='utf-8',creationflags=subprocess.CREATE_NO_WINDOW)
        self.q=queue.Queue()
        def read():
            for line in self.process.stdout:self.q.put(line)
        threading.Thread(target=read,daemon=True).start()
    def next(self):
        line=self.q.get(timeout=120);start=line.find('{');assert start>=0,'No JSON peer receipt';return line[start:]
    def call(self,input):
        self.process.stdin.write(json.dumps(input,ensure_ascii=False)+'\n');self.process.stdin.flush();return self.next()
    def close(self):
        if not self.process.stdin.closed:self.process.stdin.close()
        self.process.wait(timeout=15)
def helper_call(action,**data):return json.loads(helper.call(dict(action=action,**data)))
def call(command,**data):
    text=agent.call(dict(command=command,**data))
    assert '"sessionSecret"' not in text and '"endCapability"' not in text
    record('agent-result-clean',helper_call('scan',text=text)['clean'])
    parsed=json.loads(text)
    metadata={k:v for k,v in parsed.items() if k!='chunks'}
    with (out/'agent-metadata.jsonl').open('a',encoding='utf-8') as log:log.write(json.dumps(dict(command=command,result=metadata),ensure_ascii=False)+'\n')
    return parsed
def control(action):
    p=subprocess.run([str(cli),'app',action,'--pid',str(process.pid)],capture_output=True,text=True,encoding='utf-8',timeout=65,creationflags=subprocess.CREATE_NO_WINDOW);value=json.loads(p.stdout)
    facts['checks'].append(dict(check='control-'+action,code=p.returncode,result=value));return value
def start(profile):
    global process
    assert process is None or process.poll() is not None
    child=env.copy();(temp/profile).mkdir(exist_ok=True);child['LOCALAPPDATA']=str(temp/profile)
    log=(out/(profile+'-app.txt')).open('wb');handles.append(log);process=subprocess.Popen([str(app)],cwd=app.parent,env=child,stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT)
    end=time.monotonic()+30
    while time.monotonic()<end:
        assert process.poll() is None
        if call('capabilities')['status']=='ok':return
        time.sleep(.2)
    raise RuntimeError('Packaged service did not start')
def stop():record('actual-process-exited',control('quit')['status']=='exited' and process.wait(timeout=5)==0)
def observe(filename,seconds=480):
    deadline=time.monotonic()+seconds
    while not (out/filename).is_file():
        assert time.monotonic()<deadline,'No bounded actual operator observation';time.sleep(.2)
    record(filename,json.loads((out/filename).read_text(encoding='utf-8'))['observed'])
def approved(request):
    end=time.monotonic()+240
    while time.monotonic()<end:
        value=call('status',requestId=request)
        if value['status']!='pending':record('owner-approved',value['status']=='approved');return value
        time.sleep(.5)
    raise RuntimeError('No synthetic owner approval')
def launch(endpoint):return dict(receiver='gh_token',executable=str(gh),argv=['api',endpoint,'--method','GET'],cwd=str(temp),env=dict(GH_TOKEN=dict(secret='gh')))
try:
    for p,b in locks.items():p.write_bytes(b.replace(b'https://pub.dev',b'https://pub.flutter-io.cn'))
    for name,args in [('format',['format','test/support/packaged_joint_fixture.dart']),('pub',['pub','get','--enforce-lockfile','--offline']),('analyze',['analyze','--fatal-infos'])]:
        with (out/(name+'.txt')).open('wb') as log:p=subprocess.run([dart,*args],cwd=r/'packages/info_storage',env=env,stdout=log,stderr=subprocess.STDOUT,timeout=150)
        record(name,p.returncode==0)
    helper=Peer([dart,'run','test/support/packaged_joint_fixture.dart',str(temp),str(receiver)],r/'packages/info_storage','fixture',env)
    initial=json.loads(helper.next());record('fixture-prepared',initial['status']=='prepared')
    agent=Peer([str(cli)],cli.parent,'agent')
    with socket.socket() as test:test.bind(('127.0.0.1',47125))
    start('source');record('session',call('session',chatLabel='整包运行与备份虚构验收')['status']=='ok')
    request=call('request-use',purpose='同一批准执行两条只读gh命令，使用假Token预期HTTP401；不使用真实GitHub登录。',credentials=[dict(alias='gh',credentialId=initial['credentials']['gh'],version=1)],launch=launch('user'))
    record('command-pending',request['status']=='pending');request_id=request['requestId']
    phase('approve-two-command-use',pid=process.pid,requestId=request_id,localAppData=str(temp/'source'))
    decision=approved(request_id);deadline=decision['decision']['credentialUse']['expiresAt'];executions=[]
    for index,endpoint in enumerate(['user','user/repos']):
        plan=launch(endpoint);op='packaged-gh-'+str(index)
        accepted=call('run-use',requestId=request_id,operationId=op,launch=plan);record('command-accepted-'+str(index),accepted['status']=='accepted');eid=accepted['executionId'];executions.append(eid)
        end=time.monotonic()+90
        while time.monotonic()<end:
            state=call('execution-status',executionId=eid)
            if state.get('executionState') in ['exited','start_failed','prepare_failed','unknown']:break
            time.sleep(.4)
        record('actual-gh-401-exit-'+str(index),state.get('executionState')=='exited' and state.get('exitCode')==1,state=state)
        output=call('execution-output',executionId=eid)
        text=b''.join(base64.b64decode(chunk['dataBase64']) for chunk in output['chunks']).decode('utf-8',errors='replace')
        record('decoded-output-clean-'+str(index),helper_call('scan',text=text)['clean'])
        record('http401-not-network-error-'+str(index),'HTTP 401' in text)
        duplicate=call('run-use',requestId=request_id,operationId=op,launch=plan)
        record('command-duplicate-'+str(index),duplicate.get('duplicate') is True and duplicate.get('executionId')==eid)
        after=call('status',requestId=request_id)['decision']['credentialUse']
        record('same-grant-deadline-'+str(index),after['expiresAt']==deadline and after['state']=='available' and after['operationCount']==index+1)
    record('two-distinct-executions',len(set(executions))==2)
    receiver_ready=helper_call('receiver-start');record('receiver-started',receiver_ready['status']=='receiver_ready')
    phase('focus-password-for-discovery',receiverPid=receiver_ready['processId'],receipt=str(out/'focused-discovery.json'))
    observe('focused-discovery.json',180)
    target=call('focus-target');record('actual-target-ready',target.get('targetState')=='ready')
    requested=call('request-use',purpose='仅向本机合成密码框填入自动生成的假密码，不登录任何网站。',credentials=[dict(alias='password',credentialId=initial['credentials']['fill'],version=1)],fill=dict(application=target['application'],targetHint='本机无网络的合成输入框'))
    record('fill-pending',requested['status']=='pending');fill_request=requested['requestId']
    phase('approve-local-focused-fill',pid=process.pid,requestId=fill_request)
    approved(fill_request)
    phase('refocus-empty-password',receiverPid=receiver_ready['processId'],receipt=str(out/'refocused.json'))
    observe('refocused.json',180)
    fill=call('fill-use',requestId=fill_request,operationId='packaged-fill-1');record('fill-accepted',fill['status']=='accepted')
    end=time.monotonic()+20
    while time.monotonic()<end:
        result=call('fill-status',requestId=fill_request,operationId='packaged-fill-1')
        if result.get('fillState')!='checking':break
        time.sleep(.2)
    record('fill-sent',result.get('fillState')=='sent')
    verified=helper_call('receiver-verify');facts['receiverVerification']=verified
    record('masked-receiver-matches-without-clipboard',verified['matches'] and verified['noPaste'] and verified['clipboardUnchanged'])
    record('receiver-closed',helper_call('receiver-close')['status']=='receiver_closed')
    backup=temp/'current9.aimbackup';recovery=temp/'current9.recovery.txt'
    phase('export-current-format9',pid=process.pid,backup=str(backup),recovery=str(recovery),receipt=str(out/'exported-observed.json'))
    observe('exported-observed.json');record('actual-export-files',backup.is_file() and recovery.is_file());stop()
    preview=helper_call('backup-inspect');facts['backupInspection']=preview
    record('format9-complete-content',preview['format']==9 and preview['information']==1 and preview['credentials']==2 and preview['attachments']==2 and preview['currentAttachments']==1 and preview['fileDeliveries']==1 and preview['credentialUseFacts']==2 and preview['executionFacts']==2 and preview['fillFacts']==1)
    source_check=helper_call('inspect',profile='source');facts['sourceInspection']=source_check
    record('source-past-and-current-originals',source_check['originalMatches'] and source_check['currentMatches'] and source_check['credentialBytesMatch'])
    start('restored');phase('restore-current-format9',pid=process.pid,backup=str(backup),recovery=str(recovery),receipt=str(out/'restored-observed.json'))
    observe('restored-observed.json')
    negative=call('run-use',requestId=request_id,operationId='packaged-gh-0',launch=launch('user'))
    record('old-command-authority-not-restored',negative.get('status')=='unauthorized' and negative.get('operationClaimed') is False)
    negative_fill=call('fill-use',requestId=fill_request,operationId='packaged-fill-1')
    record('old-fill-authority-not-restored',negative_fill.get('status')=='unauthorized' and negative_fill.get('operationClaimed') is False)
    stop();check=helper_call('inspect',profile='restored');facts['restoredInspection']=check
    record('restored-complete-originals-and-facts',check['originalMatches'] and check['currentMatches'] and check['credentialBytesMatch'] and check['credentialRequests']==2 and check['executions']==2 and check['executionsExitedOne'] and check['fills']==1 and check['fillsSent'] and check['fileDeliveries']==1 and check['noHeldCopies'])
    record('past-facts-archived',check['requestsArchived'] and check['executionsArchived'] and check['fillsArchived'])
    facts['complete']=True;phase('complete')
finally:
    if process is not None and process.poll() is None:
        if control('quit')['status']=='exited':process.wait(timeout=6)
    if agent is not None:agent.close()
    if helper is not None:
        try:helper_call('receiver-close')
        finally:helper.close()
    for h in handles:h.close()
    bad=[]
    for p,b in locks.items():
        if norm(p.read_bytes())!=norm(b):bad.append(str(p))
        else:p.write_bytes(b)
    facts['unexpectedLocks']=bad
    if facts['complete'] and (process is None or process.poll() is not None):
        assert temp.parent==Path(tempfile.gettempdir()).resolve() and temp.name.startswith('aim-packaged-joint-')
        assert not any(p.is_symlink() or p.is_junction() for p in temp.rglob('*'));shutil.rmtree(temp);facts['temporaryRemoved']=not temp.exists()
    else:facts['preservedTemporary']=str(temp)
    (out/'result.json').write_text(json.dumps(facts,indent=2)+'\n',encoding='utf-8');assert not bad,bad
