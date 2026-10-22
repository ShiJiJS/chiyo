from pathlib import Path
import json,hashlib,shutil,re,subprocess,zipfile

root=Path.cwd();out=root/'build/macos-adaptation/issue50-package-15'
state=json.loads((out.parent/'issue50-package-15-job.json').read_text())
assert state['complete'] and state['sourceCommit']=='c6958daabcd77862f436db5088e08bb0bf3fa6b4'
assert subprocess.check_output(['git','branch','--show-current'],text=True).strip()=='codex/macos-adaptation'
assert not subprocess.check_output(['git','status','--porcelain'])
ev=root/'docs/development/evidence/macos-package-c6958da';raw=ev/'raw';raw.mkdir(parents=True,exist_ok=True)
shutil.copytree(out/'logs',raw/'logs',dirs_exist_ok=True)
for source,name in [(out/'verification.json','package-verification.json'),(out/'preserved-manifest.json','manifest.json'),(out.parent/'issue50-package-15-job.py','supervisor.py'),(out.parent/'issue50-package-15-job.json','supervisor.json'),(out.parent/'issue50-package-15-source-hashes.json','source-hashes.json'),(out.parent/'issue50-package-15-run.txt','run.txt')]:shutil.copy2(source,raw/name)
shutil.copy2(__file__,raw/'archive.py')
checks=re.findall(r'\+(\d+)(?:\s+~(\d+))?: All tests passed!',(out/'logs/source-checks.txt').read_text())
assert checks==[('285','6'),('75','40'),('159','18'),('215','2')],checks
manifest=json.loads((raw/'manifest.json').read_text())
assert manifest['sourceCommit']==state['sourceCommit'] and manifest['sourceChecksRequested']
assert manifest['appIdentity']=='com.example.infoDesktop' and manifest['sdkRequiredAtRuntime'] is False
assert manifest['appEntitlements']['com.apple.security.app-sandbox'] and manifest['workerEntitlements']['com.apple.security.inherit']
assert not manifest['appEntitlements'].get('com.apple.security.get-task-allow',False)
archive=root/state['archive'];assert hashlib.sha256(archive.read_bytes()).hexdigest()==state['archiveSha256']
# Read the exact Mach-O out of the preserved ZIP, without another registered app.
name='app/info_desktop.app/Contents/MacOS/info_desktop'
row=next(e for e in manifest['files'] if e['path']==name)
with zipfile.ZipFile(archive) as z:b=z.read('AgentInfoManage/'+name)
assert hashlib.sha256(b).hexdigest()==row['sha256'] and len(b)==row['bytes']
probe=out/'native-symbol-probe';assert not probe.exists();probe.write_bytes(b)
try:
 result=subprocess.run(['/usr/bin/nm','-j',str(probe)],capture_output=True,text=True)
 symbols=[s for s in result.stdout.splitlines() if any(x in s for x in ['NativeSecretEditor','NativeTextEditingMenu','routeQuitMenu'])]
 (raw/'native-symbols.txt').write_text('\n'.join(symbols)+'\n')
 native={'executablePath':name,'executableSha256':row['sha256'],'nmExit':result.returncode,'symbolMatches':len(symbols),'nativeSecretEditorPresent':any('NativeSecretEditor' in s for s in symbols),'nativeEditingMenuPresent':any('NativeTextEditingMenu' in s for s in symbols),'exactZIPEntryMatchesManifest':True,'temporaryExecutableRemoved':True}
 assert result.returncode==0 and native['nativeSecretEditorPresent'] and native['nativeEditingMenuPresent']
finally:probe.unlink()
(raw/'native-inclusion.json').write_text(json.dumps(native,indent=2)+'\n')
(ev/'.gitattributes').write_text('* -text -diff\n**/* -text -diff\n')
v={**state,'date':'2026-10-22','packageSourceCheckPassed':sum(int(x[0]) for x in checks),'packageSourceCheckConditionalSkipped':sum(int(x[1]) for x in checks),'sourceSuiteCounts':dict(zip(['Core','CLI','Storage','Desktop'],[{'passed':int(x[0]),'skipped':int(x[1])} for x in checks])),'countsNotAddedToOverlappingExtractedChecks':True,'payloadFileAndLinkCount':len(manifest['files']),'machOCount':len(manifest['machO']),'nativeBinaryInclusion':native,'ordinaryNewPackageUiVerified':False,'keychainUpgradeVerified':False,'physicalImeVerified':False,'cleanUserVerified':False,'productionKeychainAccessRequested':False,'newSystemPermissionRequests':0,'issue50Criteria':[True,True,False,False,False,False]}
v['files']=[{'path':str(p.relative_to(ev)),'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(raw.rglob('*')) if p.is_file()]
(ev/'verification.json').write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'rawFiles':len(v['files']),'archive':state['archive'],'archiveBytes':state['archiveBytes'],'archiveSha256':state['archiveSha256'],'manifestSha256':state['manifestSha256'],'sourceCounts':v['sourceSuiteCounts'],'payloadCount':v['payloadFileAndLinkCount'],'machOCount':v['machOCount'],'releasedKiB':state['releasedAllocatedKiB'],'nativeInclusion':native},ensure_ascii=False,indent=2))
