from pathlib import Path
import importlib.util,json,hashlib,zipfile,subprocess,shutil,re
r=Path.cwd();b=r/'build/macos-adaptation/issue48-native-values-20261022';p=r/'build/macos-adaptation/issue50-package-20';raw=b/'evidence/raw/package20-final';raw.mkdir(parents=True,exist_ok=True)
spec=importlib.util.spec_from_file_location('pkg',r/'scripts/package-macos.py');mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
d=json.loads((p/'verification.json').read_text());assert d['sourceCommit']=='ca5fe69f79169b1f642aa05416faa19123636558' and d['complete'] and len(d['phases'])==21 and all(x['exit']==0 for x in d['phases'])
z=p/d['archive'];zhash=hashlib.sha256(z.read_bytes()).hexdigest();assert zhash==d['archiveSha256']
with zipfile.ZipFile(z) as archive:
 names=[n for n in archive.namelist() if n.endswith('/manifest.json') and n.count('/')==1];assert len(names)==1;mbytes=archive.read(names[0]);m=json.loads(mbytes)
 assert m['sourceCommit']==d['sourceCommit'] and not m['sourceDirty'] and m['sourceChecksRequested']
 executable='app/info_desktop.app/Contents/MacOS/info_desktop';prefix=names[0][:-len('manifest.json')];binary=archive.read(prefix+executable);entry=next(x for x in m['files'] if x['path']==executable);assert hashlib.sha256(binary).hexdigest()==entry['sha256']
 binaryPath=b/'packaged-desktop-macho';binaryPath.write_bytes(binary)
 try:
  nm=subprocess.check_output(['/usr/bin/nm','-nm',str(binaryPath)],text=True);symbols=[x for x in nm.splitlines() if 'NativeTextFieldAccessibility' in x];assert symbols; (raw/'native-accessibility-symbols.txt').write_text('\n'.join(symbols)+'\n')
 finally:binaryPath.unlink()
for payload in [p/'AgentInfoManage',p/d['extractedDirectory']]:
 assert (payload/'manifest.json').read_bytes()==mbytes and mod.inventory(payload)==m['files']

(raw/'manifest.json').write_bytes(mbytes);(p/'preserved-manifest.json').write_bytes(mbytes);shutil.copy2(p/'verification.json',raw/'verification.json');shutil.copytree(p/'logs',raw/'logs',dirs_exist_ok=True)
s=(p/'logs/source-checks.txt').read_text();counts=[(int(a),int(skip or '0')) for a,skip in re.findall(r'\+(\d+)(?: ~(\d+))?: All tests passed!',s)];assert len(counts)==4,counts
assert counts==[(290,6),(75,40),(160,18),(255,2)],counts
facts={'source':d['sourceCommit'],'archive':str(z.relative_to(r)),'archiveBytes':z.stat().st_size,'archiveSha256':zhash,'phases':len(d['phases']),'counts':{'core':counts[0],'cli':counts[1],'storage':counts[2],'desktop':counts[3]},'totalPassed':sum(x[0] for x in counts),'conditionalSkips':sum(x[1] for x in counts),'manifestFiles':len(m['files']),'machOFiles':len(m['machO']),'uncompressedCopiesVerified':2,'packagedNativeAdapterSymbols':len(symbols),'packagedDesktopSha256':entry['sha256'],'stableInstalledPreviewReplaced':False,'ordinaryFinalGUIOrCleanUserClaimed':False,'newKeychainRequests':0}
(raw/'delivery-audit.json').write_text(json.dumps(facts,ensure_ascii=False,indent=2)+'\n')
removed=[];unregistered=[]
for q in [p/'AgentInfoManage',p/'diagnostic-build',p/'verify',r/'apps/desktop/build',r/'apps/desktop/.dart_tool/flutter_build',r/'apps/desktop/.dart_tool/hooks_runner']:
 if not q.exists():continue
 assert q.is_dir() and not q.is_symlink() and str(q) not in subprocess.check_output(['ps','-axo','pid,comm'],text=True)
 for app in q.rglob('info_desktop.app'):
  op=subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister','-u',str(app)],capture_output=True,text=True);unregistered.append({'path':str(app.relative_to(r)),'exitCode':op.returncode})
 kb=int(subprocess.check_output(['du','-sk',str(q)],text=True).split()[0]);shutil.rmtree(q);removed.append({'path':str(q.relative_to(r)),'allocatedKiB':kb})
(raw/'cleanup.json').write_text(json.dumps({'removed':removed,'unregisterOperations':unregistered,'releasedAllocatedKiB':sum(x['allocatedKiB'] for x in removed),'finalZipRetained':True,'sdkAndCachePreserved':True},ensure_ascii=False,indent=2)+'\n');print(json.dumps(facts,ensure_ascii=False));print('cleanedMiB',sum(x['allocatedKiB'] for x in removed)/1024)
