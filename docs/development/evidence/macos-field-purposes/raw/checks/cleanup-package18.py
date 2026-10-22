from pathlib import Path
import json,shutil,subprocess
r=Path.cwd();p=r/'build/macos-adaptation/issue50-package-18';raw=r/'build/macos-adaptation/issue48-field-purposes-20261022/evidence/raw/package18-final';d=json.loads((raw/'delivery-audit.json').read_text());assert d['uncompressedCopiesVerified']==2
removed=[];unregister=[]
for q in [p/'AgentInfoManage',p/'diagnostic-build',p/'verify',r/'apps/desktop/build',r/'apps/desktop/.dart_tool/flutter_build',r/'apps/desktop/.dart_tool/hooks_runner']:
 if not q.exists():continue
 assert q.is_dir() and not q.is_symlink() and str(q) not in subprocess.check_output(['ps','-axo','pid,comm'],text=True)
 # The two package copies were already unregistered before the delivery audit
 # was written. Do not repeat their successful unregister operations.
 if q==r/'apps/desktop/build':
  for app in q.rglob('info_desktop.app'):
   a=subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister','-u',str(app)],capture_output=True,text=True);unregister.append({'path':str(app.relative_to(r)),'exitCode':a.returncode,'stderr':a.stderr})
 kb=int(subprocess.check_output(['du','-sk',str(q)],text=True).split()[0]);shutil.rmtree(q);removed.append({'path':str(q.relative_to(r)),'allocatedKiB':kb})
(raw/'cleanup.json').write_text(json.dumps({'removed':removed,'releasedAllocatedKiB':sum(x['allocatedKiB'] for x in removed),'finalZipRetained':True,'intermediate17ZipNotRetained':True,'sdkAndCachePreserved':True,'packageCopyUnregisterExitCodes':[0,0],'rootBuildUnregister':unregister,'preparationError':'First cleanup repeated the already successful unregister for the package copy, received exit1 and stopped before any deletion. Cleanup resumed without repeating those operations.'},ensure_ascii=False,indent=2)+'\n');print('cleanedMiB',sum(x['allocatedKiB'] for x in removed)/1024)
