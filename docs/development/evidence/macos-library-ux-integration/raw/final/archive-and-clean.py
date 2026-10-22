from pathlib import Path
import os,stat,subprocess,hashlib,json,shutil
r=Path.cwd();o=r/'build/macos-adaptation/issue41-library-ux-integration-20261022';p=r/'build/macos-adaptation/issue50-package-16';e=o/'final-evidence';e.mkdir(exist_ok=True)
sha=lambda x:hashlib.sha256(x.read_bytes()).hexdigest()
assert subprocess.check_output(['git','branch','--show-current'],text=True).strip()=='codex/macos-adaptation'
package=json.loads((p/'verification.json').read_text());assert package['complete'] and all(x['exit']==0 for x in package['phases'])
archive=p/package['archive'];assert sha(archive)==package['archiveSha256'];shutil.copy2(p/'AgentInfoManage/manifest.json',p/'preserved-manifest.json')
m=json.loads((p/'preserved-manifest.json').read_text());assert m['sourceCommit']=='5a509968400b2d140a69a02f89935c5db4e935ee'
for name in ['compatibility-2','schema20-22-1']:
 state=json.loads((o/name/'result.json').read_text());assert state['complete']
 q=e/name;q.mkdir(exist_ok=True)
 for f in (o/name).iterdir():
  if f.is_file() and f.suffix in ['.json','.dart','.txt']:shutil.copy2(f,q/f.name)
for f in p.glob('*.json'):shutil.copy2(f,e/f.name)
shutil.copytree(p/'logs',e/'package-logs',dirs_exist_ok=True)
for name in ['package-supervisor.txt','schema20-22-supervisor.txt','compatibility-2-supervisor.txt','source-diff-check.txt']:shutil.copy2(o/name,e/name)
shutil.copy2(r/'scripts/qa/check-macos-organization-compatibility.py',e/'check-macos-organization-compatibility.py')
shutil.copy2(r/'scripts/qa/macos-schema-upgrade-probe.dart',e/'macos-schema-upgrade-probe.dart')
shutil.copy2(r/'scripts/qa/macos-schema-upgrade.py',e/'macos-schema-upgrade.py')
# Validate the complete payload before discarding its uncompressed copies.
def verify(base,manifest):
 for row in manifest['files']:
  x=base/row['path']
  if 'link' in row:assert x.is_symlink() and os.readlink(x)==row['link']
  else:assert x.is_file() and not x.is_symlink() and x.stat().st_size==row['bytes'] and stat.S_IMODE(x.stat().st_mode)==row['mode'] and sha(x)==row['sha256'],row['path']
verify(p/'AgentInfoManage',m);verify(p/package['extractedDirectory'],m)
targets=[o/f'native-{n}/source' for n in [1,2,3]]
for n in ['compatibility-1','compatibility-2']:
 targets += [o/n/s for s in ['old-source','current-source','aot-old-producer','aot-upgrade','aot-old-reader']]
targets += [o/'schema20-22-1'/s for s in ['legacy-source','current-source','legacy-aot','current-aot','legacy.zip','current.zip']]
targets += [p/s for s in ['AgentInfoManage','verify','diagnostic-build']]
targets += [r/'apps/desktop/build'/s for s in ['macos','native_assets','test_cache','unit_test_assets']]
targets += [r/'apps/desktop/.dart_tool'/s for s in ['hooks_runner','mac-compact-capture.dart']]
processes=subprocess.check_output(['ps','-axo','pid,comm'],text=True)
for target in targets:
 assert target.is_relative_to(r) and target!=r
 assert not any(str(target)+'/' in line for line in processes.splitlines()),str(target)
apps=[]
for target in targets:
 if target.is_dir():
  for path,dirs,files in os.walk(target,followlinks=False):
   for name in dirs[:]:
    x=Path(path)/name
    if x.is_symlink():dirs.remove(name)
    elif name.endswith('.app'):apps.append(x);dirs.remove(name)
registration=[];lsregister='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
for app in apps:
 c=subprocess.run([lsregister,'-u',str(app)],capture_output=True,text=True)
 assert c.returncode==0,(app,c.stderr)
 registration.append({'path':str(app.relative_to(r)),'exit':c.returncode})
removed=[]
for target in targets:
 if not target.exists():continue
 assert not target.is_symlink()
 kb=int(subprocess.check_output(['du','-sk',str(target)],text=True).split()[0])
 if target.is_dir():shutil.rmtree(target)
 else:target.unlink()
 removed.append({'path':str(target.relative_to(r)),'allocatedKiB':kb})
install=r/'local/中文 Mac 预览/AgentInfoManage';stable=json.loads((install/'manifest.json').read_text());verify(install,stable)
c=subprocess.run(['codesign','--verify','--deep','--strict',str(install/'app/info_desktop.app')],capture_output=True,text=True);assert c.returncode==0
os.kill(53592,0)
remaining=[];symbols=[]
for area in [r/'build/macos-adaptation',r/'local',r/'apps/desktop/build']:
 for path,dirs,files in os.walk(area,followlinks=False):
  for name in dirs[:]:
   x=Path(path)/name
   if x.is_symlink():dirs.remove(name)
   elif name.endswith(('.app','.dSYM')):
    (remaining if name.endswith('.app') else symbols).append(str(x.relative_to(r)));dirs.remove(name)
assert remaining==['local/中文 Mac 预览/AgentInfoManage/app/info_desktop.app'] and not symbols
assert (r/'local/private/mac-upgrade-20261022/encrypted-backup/工作目录修复前 合成资料.aimbackup').is_file()
assert (r/'local/private/mac-upgrade-20261022/recovery-key/升级前 恢复密钥.txt').is_file()
assert sha(archive)==package['archiveSha256']
result={'unregistered':registration,'removed':removed,'releasedAllocatedKiB':sum(x['allocatedKiB'] for x in removed),'stableItemsVerified':len(stable['files']),'stableMismatches':0,'stableSignatureExit':0,'stablePid53592Alive':True,'remainingApps':remaining,'remainingGeneratedDsyms':symbols,'oldAndNewZIPsSDKsPrivateBackupsRecoveryKeysPreserved':True,'newPackageSource':m['sourceCommit'],'newPackageArchive':str(archive.relative_to(r)),'newPackageSha256':sha(archive),'newPackageBytes':archive.stat().st_size,'payloadEntriesVerifiedPerCopy':len(m['files'])}
(e/'cleanup.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n');shutil.copy2(__file__,e/'archive-and-clean.py');print(json.dumps(result,ensure_ascii=False))
