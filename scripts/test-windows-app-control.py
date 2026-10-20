"""Verify the packaged Windows lifecycle with isolated synthetic data.

An operator approves only the requested dummy fields, observes the normal pages,
closes the window, then creates hidden.json with {"observed": true} in --evidence.
At observe-startup-error, inspect the error window and similarly create
startup-error-observed.json. These receipts are actual operator observations,
not automated screenshot assertions. The CLI performs all process exits.
Use --tail-only to isolate restart/startup-error checks; it does not test grants.
"""
from pathlib import Path
import argparse,hashlib,json,os,queue,shutil,socket,subprocess,sys,tempfile,threading,time
sys.stdout.reconfigure(encoding='utf-8')
p=argparse.ArgumentParser();p.add_argument('--dart',type=Path,required=True);p.add_argument('--delivery',type=Path,required=True);p.add_argument('--evidence',type=Path,required=True);p.add_argument('--tail-only',action='store_true');a=p.parse_args()
root=Path(__file__).resolve().parent.parent;delivery=a.delivery.resolve(strict=True);out=a.evidence.resolve();out.mkdir(parents=True,exist_ok=False)
manifest=json.loads((delivery/'manifest.json').read_text(encoding='utf-8-sig'))
for entry in manifest['files']:
    f=(delivery/entry['path']).resolve(strict=True);assert f.is_relative_to(delivery)
    assert f.stat().st_size==entry['bytes'] and hashlib.sha256(f.read_bytes()).hexdigest()==entry['sha256']
app=delivery/'app/info_desktop.exe';cli=delivery/'cli/info.exe'
temp=Path(tempfile.mkdtemp(prefix='aim-app-control-')).resolve();assert temp.parent==Path(tempfile.gettempdir()).resolve()
env=os.environ.copy();env.update(PUB_HOSTED_URL='https://pub.flutter-io.cn',FLUTTER_STORAGE_BASE_URL='https://storage.flutter-io.cn')
locks={root/x/'pubspec.lock':(root/x/'pubspec.lock').read_bytes() for x in ['packages/info_core','packages/info_cli','packages/info_storage','apps/desktop']}
norm=lambda b:b.replace(b'https://pub.flutter-io.cn',b'https://pub.dev').replace(b'\r\n',b'\n')
facts={'sourceCommit':manifest['sourceCommit'],'release':manifest['release'],'checks':[],'complete':False}
process=None;agent=None;blocker=None;streams=[]
def check(name,condition,**data):
    facts['checks'].append(dict(check=name,passed=bool(condition),**data));assert condition,name
def phase(name,**data):
    value=dict(phase=name,**data);(out/'phase.json').write_text(json.dumps(value,ensure_ascii=False,indent=2),encoding='utf-8');print(json.dumps(value,ensure_ascii=False),flush=True)
def control(action,*args):
    r=subprocess.run([str(cli),'app',action,*args],cwd=delivery/'cli',capture_output=True,text=True,encoding='utf-8',timeout=65,creationflags=subprocess.CREATE_NO_WINDOW)
    result=json.loads(r.stdout);facts['checks'].append(dict(check='control-'+action,exitCode=r.returncode,result=result));return r.returncode,result
def helper(action):
    helper_path=root/'packages/info_storage/test/support/packaged_control_fixture.dart'
    return [str(a.dart.resolve(strict=True)),'run',str(helper_path),action,str(temp)]
def start(profile):
    global process
    assert process is None or process.poll() is not None
    child=env.copy();child['LOCALAPPDATA']=str(temp/profile)
    log=(out/(profile+'-'+str(time.time_ns())+'-app.txt')).open('wb');streams.append(log)
    process=subprocess.Popen([str(app)],cwd=app.parent,env=child,stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT)
    end=time.monotonic()+30
    while time.monotonic()<end:
        assert process.poll() is None,'App exited during startup'
        code,state=control('status','--pid',str(process.pid))
        if state['status']=='running':return
        time.sleep(.2)
    raise RuntimeError('Control handler not ready')
class Agent:
    def __init__(self):
        self.log=(out/'agent-errors.txt').open('wb');streams.append(self.log)
        self.process=subprocess.Popen([str(cli)],cwd=cli.parent,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=self.log,text=True,encoding='utf-8',creationflags=subprocess.CREATE_NO_WINDOW)
        self.q=queue.Queue()
        def read():
            for line in self.process.stdout:self.q.put(line)
        threading.Thread(target=read,daemon=True).start()
    def call(self,command,**args):
        self.process.stdin.write(json.dumps(dict(command=command,**args),ensure_ascii=False)+'\n');self.process.stdin.flush()
        return json.loads(self.q.get(timeout=45))
    def close(self):
        if self.process.stdin and not self.process.stdin.closed:self.process.stdin.close()
        self.process.wait(timeout=10);assert self.process.returncode==0
def wait_approved(request):
    end=time.monotonic()+240
    while time.monotonic()<end:
        state=agent.call('status',requestId=request)
        if state['status']!='pending':check('owner-approved',state['status']=='approved');return
        time.sleep(.4)
    raise RuntimeError('Operator did not approve synthetic request')
try:
    for f,b in locks.items():f.write_bytes(b.replace(b'https://pub.dev',b'https://pub.flutter-io.cn'))
    with (out/'fixture-prepare.txt').open('wb') as log:
        r=subprocess.run(helper('prepare'),cwd=root/'packages/info_storage',env=env,stdout=log,stderr=subprocess.STDOUT,timeout=90);assert r.returncode==0,'Fixture prepare failed'
    fixture=json.loads((temp/'fixture.json').read_text(encoding='utf-8'))
    # Only start a synthetic default-port instance when the port is free.
    with socket.socket() as test:test.bind(('127.0.0.1',47125))
    code,state=control('status');check('no-peer-before-start',code==0 and state['status']=='not_running')
    if a.tail_only:
        start('normal');agent=Agent()
        end=time.monotonic()+30
        while time.monotonic()<end:
            opened=agent.call('session',chatLabel='Windows生命周期虚构尾段')
            if opened['status']=='ok':break
            time.sleep(.2)
        check('fresh-session',opened['status']=='ok')
        check('session-valid-before-exit',agent.call('session-check')['status']=='ok')
        code,state=control('quit');check('initial-normal-exits',code==0 and state['status']=='exited' and process.wait(timeout=5)==0)
    else:
        start('normal');agent=Agent()
        end=time.monotonic()+30
        while time.monotonic()<end:
            capability=agent.call('capabilities')
            if capability['status']=='ok':break
            time.sleep(.2)
        check('release-service-ready',capability['status']=='ok')
        check('session-opened',agent.call('session',chatLabel='Windows整包虚构验收')['status']=='ok')
        requested=agent.call('request',purpose='混合资料验收：请批准访问地址和虚构简历文件，不批准维护账号。文件可读取原文，用后释放。',fields=[
            dict(itemId=fixture['serverId'],fieldId=fixture['addressField']),dict(itemId=fixture['serverId'],fieldId=fixture['accountField']),dict(itemId=fixture['documentId'],fieldId=fixture['documentField'])])
        check('pending-request',requested['status']=='pending');request=requested['requestId']
        phase('approve-mixed-fields',pid=process.pid,requestId=request,localAppData=str(temp/'normal'))
        wait_approved(request)
        claim=agent.call('claim',requestId=request)
        check('partial-scope',claim['status']=='ok' and len(claim['fields'])==2 and {f['fieldId'] for f in claim['fields']}=={fixture['addressField'],fixture['documentField']})
        first_expiry=claim['expiresAt']
        for i in range(3):
            read=agent.call('read',requestId=request,itemId=fixture['serverId'],fieldId=fixture['addressField'])
            check('approved-read-'+str(i),read['status']=='ok' and read['value']=='https://synthetic.example.invalid')
        check('unapproved-denied',agent.call('read',requestId=request,itemId=fixture['serverId'],fieldId=fixture['accountField'])['status']=='unauthorized')
        check('same-expiry',agent.call('claim',requestId=request)['expiresAt']==first_expiry)
        file_request=request
        check('file-claim',agent.call('claim',requestId=file_request)['status']=='ok')
        delivered=agent.call('file-fetch',requestId=file_request,itemId=fixture['documentId'],fieldId=fixture['documentField'],operationId='packaged-control-file')
        check('file-ready',delivered.get('status')=='ok' and delivered.get('delivery',{}).get('state')=='ready')
        copy=Path(delivered['delivery']['path']);check('copy-bytes',copy.read_bytes()==(temp/'fictional-resume.txt').read_bytes())
        released=agent.call('file-release',deliveryId=delivered['delivery']['deliveryId'])
        check('file-released',released.get('status')=='ok' and released['delivery']['state']=='released' and not copy.exists())
        phase('browse-tabs-and-hide',pid=process.pid)
        deadline=time.monotonic()+240
        while not (out/'hidden.json').exists():
            assert time.monotonic()<deadline,'Operator did not observe tabs/hide';time.sleep(.2)
        check('observed-tabs-hide',json.loads((out/'hidden.json').read_text(encoding='utf-8'))['observed'])
        code,state=control('status');check('hidden-still-running',code==0 and state['status']=='running')
        check('hidden-read',agent.call('read',requestId=request,itemId=fixture['serverId'],fieldId=fixture['addressField'])['status']=='ok')
        # Hold the actual SQLCipher database write transaction, then request quit.
        blocker=subprocess.Popen(helper('lock'),cwd=root/'packages/info_storage',env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=(out/'blocker.txt').open('wb'),text=True,encoding='utf-8')
        check('synthetic-sql-lock',json.loads(blocker.stdout.readline())['status']=='locked')
        code,state=control('quit','--timeout-ms','60000')
        check('failed-save-refuses-exit',code==1 and state['status']=='shutdown_failed' and process.poll() is None)
        code,state=control('status');check('failure-remains-queryable',code==1 and state['status']=='shutdown_failed')
        blocker.stdin.write('\n');blocker.stdin.flush();blocker.wait(timeout=15);check('write-lock-released',blocker.returncode==0);blocker=None
        code,state=control('quit');check('retry-actually-exits',code==0 and state['status']=='exited' and process.wait(timeout=5)==0)
        code,state=control('quit');check('repeat-idempotent',code==0 and state['status']=='not_running')
        check('service-closed',agent.call('read',requestId=request,itemId=fixture['serverId'],fieldId=fixture['addressField'])['status']=='service_unavailable')
        with (out/'inspect.txt').open('wb') as log:r=subprocess.run(helper('inspect'),cwd=root/'packages/info_storage',env=env,stdout=log,stderr=subprocess.STDOUT,timeout=45)
        check('library-inspect-process',r.returncode==0)
        inspection_text=(out/'inspect.txt').read_text(encoding='utf-8');inspected=json.loads(inspection_text[inspection_text.index('{"status":"inspected"'):].strip());facts['libraryInspection']=inspected
        check('exit-facts-durable',inspected['allClosed'] and inspected['grants']==1 and inspected['items']==2)
    start('normal')
    old_status=agent.call('session-check') if a.tail_only else agent.call('read',requestId=request,itemId=fixture['serverId'],fieldId=fixture['addressField'])
    check('old-proof-does-not-revive',old_status['status']=='unauthorized')
    code,state=control('quit');check('reopened-exits',code==0 and state['status']=='exited' and process.wait(timeout=5)==0)
    start('missing-key');phase('observe-startup-error',pid=process.pid)
    # Lifecycle works even though the data/service bootstrap cannot start.
    deadline=time.monotonic()+120
    while not (out/'startup-error-observed.json').exists():
        assert time.monotonic()<deadline,'Operator did not inspect error window';time.sleep(.2)
    check('startup-error-observed',json.loads((out/'startup-error-observed.json').read_text(encoding='utf-8'))['observed'])
    code,state=control('quit');check('startup-error-exits',code==0 and state['status']=='exited' and process.wait(timeout=5)==0)
    failed_db=temp/'missing-key/AgentInfoManage/library.db'
    check('failed-open-preserves-db',hashlib.sha256(failed_db.read_bytes()).hexdigest()==fixture['failedDbSha256'] and not (failed_db.parent/'database-key.dpapi').exists())
    facts['complete']=True;phase('complete',checks=len(facts['checks']))
finally:
    if blocker is not None:
        try:blocker.stdin.write('\n');blocker.stdin.flush();blocker.wait(timeout=15)
        except Exception:facts['blockerCleanupFailed']=True
    if agent is not None:
        try:agent.close()
        except Exception:facts['agentCleanupFailed']=True
    if process is not None and process.poll() is None:
        code,state=control('quit','--pid',str(process.pid),'--timeout-ms','60000')
        if state['status']=='exited':process.wait(timeout=5)
    for stream in streams:stream.close()
    bad=[]
    for f,b in locks.items():
        if norm(f.read_bytes())!=norm(b):bad.append(str(f))
        else:f.write_bytes(b)
    facts['unexpectedLocks']=bad
    if (process is None or process.poll() is not None) and not facts.get('blockerCleanupFailed'):
        assert temp.parent==Path(tempfile.gettempdir()).resolve() and temp.name.startswith('aim-app-control-')
        assert not any(f.is_symlink() or f.is_junction() for f in temp.rglob('*'))
        shutil.rmtree(temp);facts['temporaryRemoved']=not temp.exists()
    else:facts['preservedTemporary']=str(temp)
    (out/'result.json').write_text(json.dumps(facts,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    assert not bad,bad

