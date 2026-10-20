from pathlib import Path
import os,sys,json,hashlib,subprocess,tempfile,shutil,time,socket,zipfile
sys.stdout.reconfigure(encoding='utf-8')
r=Path.cwd();out=r/'build/qa-issue18-upgrade'/sys.argv[1];out.mkdir(parents=True,exist_ok=False)
payload=r/'build/windows-preview-0.4.0-11-887f1c2/AgentInfoManage';app=payload/'app/info_desktop.exe';cli=payload/'cli/info.exe'
archive=r/'build/qa-issue33/legacy16-release-source.zip';old=r/'build/qa-issue33/legacy16-release-2918010/packages/info_storage';old_probe=old/'legacy_probe.dart'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
assert sha(archive)=='7d775372e4fc710fcda55918c205a393724d9d8c794de911137575c79c491c0e'
assert sha(old_probe)=='159d9791b4c94f1302b41105ca272766fceb37f63c610c26a97f09159a8cc2d3'
checked=[]
with zipfile.ZipFile(archive) as z:
    for name in z.namelist():
        if name.startswith(('packages/info_core/lib/','packages/info_storage/lib/')) and not name.endswith('/'):
            p=old.parent.parent/name;assert p.read_bytes()==z.read(name),name;checked.append(name)
manifest=json.loads((payload/'manifest.json').read_text(encoding='utf-8-sig'))
for entry in manifest['files']:
    p=(payload/entry['path']).resolve(strict=True);assert p.is_relative_to(payload.resolve()) and sha(p)==entry['sha256'] and p.stat().st_size==entry['bytes']
temp=Path(tempfile.mkdtemp(prefix='aim-packaged-upgrade-')).resolve()
env=os.environ.copy();env.update(PUB_HOSTED_URL='https://pub.flutter-io.cn',FLUTTER_STORAGE_BASE_URL='https://storage.flutter-io.cn')
locks={r/p/'pubspec.lock':(r/p/'pubspec.lock').read_bytes() for p in ['packages/info_cli','packages/info_core','packages/info_storage','apps/desktop']}
for p in [old/'pubspec.lock',old.parent/'info_core/pubspec.lock']:
    if p.exists():locks[p]=p.read_bytes()
norm=lambda b:b.replace(b'https://pub.flutter-io.cn',b'https://pub.dev').replace(b'\r\n',b'\n')
dart='C:/Users/Todoki/.local/share/flutter/bin/dart.bat';process=None;handles=[]
facts=dict(productSource=manifest['sourceCommit'],oldSource='291801046f7d1e6e4217a4bc001ea714689855c5',archiveSha256=sha(archive),oldHelperSha256=sha(old_probe),checkedOldLibraries=len(checked),checks=[],complete=False)
def record(name,condition,**data):
    facts['checks'].append(dict(check=name,passed=bool(condition),**data));assert condition,name
def phase(name,**data):
    value=dict(phase=name,**data);(out/'phase.json').write_text(json.dumps(value,indent=2),encoding='utf-8');print(json.dumps(value),flush=True)
def run(name,cmd,cwd):
    with (out/(name+'.txt')).open('wb') as log:p=subprocess.run(cmd,cwd=cwd,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=150)
    record(name,p.returncode==0)
    text=(out/(name+'.txt')).read_text(encoding='utf-8',errors='replace');start=text.find('{"status":')
    return json.loads(text[start:].strip()) if start>=0 else None
def current(name,action,profile):
    return run(name,[dart,'run','test/support/packaged_upgrade_fixture.dart',action,str(temp),profile],r/'packages/info_storage')
def control(action):
    p=subprocess.run([str(cli),'app',action],capture_output=True,text=True,encoding='utf-8',timeout=20,creationflags=subprocess.CREATE_NO_WINDOW)
    value=json.loads(p.stdout);facts['checks'].append(dict(check='control-'+action,code=p.returncode,result=value));return value
def command(data):
    p=subprocess.run([str(cli)],input=json.dumps(data)+'\n',capture_output=True,text=True,encoding='utf-8',timeout=15,creationflags=subprocess.CREATE_NO_WINDOW)
    assert p.returncode==0;return json.loads(p.stdout)
def start(profile):
    global process
    assert process is None or process.poll() is not None
    local=temp/profile;local.mkdir(exist_ok=True)
    child=env.copy();child['LOCALAPPDATA']=str(local)
    log=(out/(profile+'-app-'+str(time.time_ns())+'.txt')).open('wb');handles.append(log)
    process=subprocess.Popen([str(app)],cwd=app.parent,env=child,stdout=log,stderr=subprocess.STDOUT,stdin=subprocess.DEVNULL)
    end=time.monotonic()+30
    while time.monotonic()<end:
        assert process.poll() is None
        value=command(dict(command='capabilities'))
        if value['status']=='ok':return
        time.sleep(.2)
    raise RuntimeError('Actual packaged service did not open '+profile)
def stop():
    record('actual-process-exited',control('quit')['status']=='exited' and process.wait(timeout=5)==0)
def inspect(name,profile):
    value=current(name,'inspect',profile);facts[name]=value
    record(name+'-facts',value['schemaBeforeOpen']==21 and value['informationMatches'] and value['credentialMatches'] and value['requests']==2 and value['onlyV1Facts'] and value['attemptsConsumed']==1 and value['unusedInvalidation']=='grant_revoked' and value['executionFacts']==1)
    return value
try:
    for p,b in locks.items():p.write_bytes(b.replace(b'https://pub.dev',b'https://pub.flutter-io.cn'))
    run('old-pub',[dart,'pub','get','--enforce-lockfile','--offline'],old)
    run('current-pub',[dart,'pub','get','--enforce-lockfile','--offline'],r/'packages/info_storage')
    run('fixture-format',[dart,'format','test/support/packaged_upgrade_fixture.dart'],r/'packages/info_storage')
    run('storage-analyze',[dart,'analyze','--fatal-infos'],r/'packages/info_storage')
    created=run('legacy-create',[dart,'run',str(old_probe),'create',str(temp/'upgraded/AgentInfoManage')],old)
    record('genuine-schema16-backup5',created==dict(status='created',schema=16,backupVersion=5))
    current('wrap-fixed-test-key','wrap','upgraded')
    envelope=temp/'upgraded/AgentInfoManage/database-key.dpapi';initial_key=sha(envelope)
    backup=temp/'upgraded/legacy5.aimbackup';recovery=temp/'upgraded/legacy-recovery.txt';backup_hash=sha(backup);recovery_hash=sha(recovery)
    with socket.socket() as test:test.bind(('127.0.0.1',47125))
    start('upgraded');catalog=command(dict(command='catalog'))
    record('upgraded-public-catalog',catalog['status']=='ok' and len(catalog['items'])==1 and catalog['items'][0]['name']=='Legacy fixture')
    old_identity=catalog['items'][0]['id'];stop()
    inspect('actual-upgraded-inspection','upgraded')
    record('source-key-backup-preserved',sha(envelope)==initial_key and sha(backup)==backup_hash and sha(recovery)==recovery_hash)
    source_db=temp/'upgraded/AgentInfoManage/library.db';source_hash=sha(source_db)
    shutil.copytree(source_db.parent,temp/'old-reader-copy/AgentInfoManage')
    old_result=run('old-reader-copy',[dart,'run',str(old_probe),'inspect',str(temp/'old-reader-copy/AgentInfoManage')],old)
    record('old-reader-refuses-copy',old_result==dict(status='rejected',errorCode='library_unavailable'))
    record('old-probe-never-touched-source',sha(source_db)==source_hash)
    facts['oldReaderChangedOnlyCopy']=sha(temp/'old-reader-copy/AgentInfoManage/library.db')!=source_hash
    start('old-reader-copy');record('current-reopens-after-old-copy-probe',command(dict(command='catalog'))['items'][0]['id']==old_identity);stop()
    inspect('old-copy-reopened-inspection','old-reader-copy')
    start('upgraded');record('upgraded-source-reopens',command(dict(command='catalog'))['items'][0]['id']==old_identity);stop()
    start('restored')
    phase('restore-format5-via-native-dialogs',pid=process.pid,localAppData=str(temp/'restored'),backup=str(backup),recovery=str(recovery),receipt=str(out/'restored-observed.json'))
    deadline=time.monotonic()+480
    while not (out/'restored-observed.json').is_file():
        assert process.poll() is None and time.monotonic()<deadline,'No actual native restore observation';time.sleep(.2)
    observed=json.loads((out/'restored-observed.json').read_text(encoding='utf-8'));record('native-preview-restore-observed',observed['observed'])
    restored=command(dict(command='catalog'));record('restored-original-identity',restored['status']=='ok' and len(restored['items'])==1 and restored['items'][0]['id']==old_identity)
    stop();value=inspect('restored-inspection','restored');record('restore-independent-local-key',value['independentKey'])
    record('original-backup-key-files-preserved',sha(backup)==backup_hash and sha(recovery)==recovery_hash)
    facts['complete']=True;phase('complete')
finally:
    if process is not None and process.poll() is None:
        value=control('quit')
        if value['status']=='exited':process.wait(timeout=5)
    for h in handles:h.close()
    bad=[]
    for p,b in locks.items():
        if norm(p.read_bytes())!=norm(b):bad.append(str(p))
        else:p.write_bytes(b)
    facts['unexpectedLocks']=bad
    if process is None or process.poll() is not None:
        assert temp.parent==Path(tempfile.gettempdir()).resolve() and temp.name.startswith('aim-packaged-upgrade-')
        assert not any(p.is_symlink() or p.is_junction() for p in temp.rglob('*'));shutil.rmtree(temp);facts['temporaryRemoved']=not temp.exists()
    else:facts['preservedTemporary']=str(temp)
    (out/'result.json').write_text(json.dumps(facts,indent=2)+'\n',encoding='utf-8');assert not bad,bad
