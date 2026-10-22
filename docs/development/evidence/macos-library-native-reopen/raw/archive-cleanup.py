from pathlib import Path
import json,shutil,hashlib,os,stat,subprocess
r=Path.cwd();b=r/'build/macos-adaptation/issue46-new-library-ui-20261022';ev=r/'docs/development/evidence/macos-library-native-reopen';raw=ev/'raw';raw.mkdir(parents=True,exist_ok=True)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
d=json.loads((b/'run-1/result.json').read_text());assert d['complete'] and d['ownedFixturesRemoved'] and not d.get('forcedFailureCleanup') and all(x==0 for x in d['unregisterExitCodes']);assert len(d['cases'])==6 and all(x['exitCode']==0 and x['libraryCloses']==1 and x['portClosedAfterExit'] for x in d['cases'])
for name,h in d['inputSourceHashes'].items():
 p=r/name;assert sha(p)==h,name
 q=b/'run-1/source'/name
 if name not in d['copyModifications']:assert q.read_bytes()==p.read_bytes()
for name,h in d['copyModifications'].items():assert sha(b/'run-1/source'/name)==h
shutil.copy2(b/'run-1/result.json',raw/'result.json');shutil.copytree(b/'run-1/logs',raw/'logs',dirs_exist_ok=True)
for p in (b/'run-1').glob('*.json'):
 assert p.name!='controller.json';shutil.copy2(p,raw/p.name)
for n in ['run-supervisor.txt','window-before-close.json','window-after-close-1.json','window-after-tool-reopen-1.json','window-after-close-2.json','after-actual-GUI-save.json','after-independent-reopen.json','sqlite-readonly-first.txt','sqlite-readonly-reopen.txt','settings-cancel.json','read-window-state.swift','read-gui-classification.py','read-gui-classification-first.py']:
 shutil.copy2(b/n,raw/n)
shutil.copy2(r/'scripts/qa/macos-lifecycle-ui.py',raw/'macos-lifecycle-ui.py');shutil.copy2(r/'apps/desktop/integration_test/macos_lifecycle_probe.dart',raw/'macos_lifecycle_probe.dart')
# Exact files used for the new UI and its native bridge, not a rebuilt substitute.
for n in ['apps/desktop/lib/main.dart','apps/desktop/lib/library.dart','apps/desktop/lib/anchored_surface.dart','apps/desktop/lib/organization_selectors.dart','apps/desktop/macos/Runner/MainFlutterWindow.swift']:
 p=raw/'frozen-product'/n;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(r/n,p)
shutil.copy2(__file__,raw/'archive-cleanup.py')
processes=subprocess.check_output(['ps','-axo','pid,comm'],text=True);assert str(b/'run-1/source') not in processes
removed=[]
for p in [b/'run-1/source',b/'first-controller.json',b/'read-window-state']:
 if not p.exists():continue
 assert not p.is_symlink();kb=int(subprocess.check_output(['du','-sk',str(p)],text=True).split()[0]);removed.append({'path':str(p.relative_to(r)),'allocatedKiB':kb})
 if p.is_dir():shutil.rmtree(p)
 else:p.unlink()
install=r/'local/中文 Mac 预览/AgentInfoManage';manifest=json.loads((install/'manifest.json').read_text());bad=[]
for row in manifest['files']:
 p=install/row['path']
 ok=(p.is_symlink() and os.readlink(p)==row['link']) if 'link' in row else (p.is_file() and not p.is_symlink() and p.stat().st_size==row['bytes'] and stat.S_IMODE(p.stat().st_mode)==row['mode'] and sha(p)==row['sha256'])
 if not ok:bad.append(row['path'])
assert not bad
c=subprocess.run(['codesign','--verify','--deep','--strict',str(install/'app/info_desktop.app')],capture_output=True,text=True);assert c.returncode==0;os.kill(53592,0)
apps=[];symbols=[]
for root in [r/'build/macos-adaptation',r/'local',r/'apps/desktop/build']:
 for path,dirs,files in os.walk(root,followlinks=False):
  for name in dirs[:]:
   p=Path(path)/name
   if p.is_symlink():dirs.remove(name)
   elif name.endswith(('.app','.dSYM')):(apps if name.endswith('.app') else symbols).append(str(p.relative_to(r)));dirs.remove(name)
assert len(apps)==1 and not symbols
archive=r/'build/macos-adaptation/issue50-package-16/agent-info-manage-0.4.1+13-mac-dev.5a509968400b-macos-arm64.zip';assert sha(archive)=='71029812dbe5c6872917b59ba4d53faecc6c355f5c530c44cbcacd7077b1e5dd'
clean={'sourceInputsVerified':len(d['inputSourceHashes']),'ownedFixturesAndAppAlreadyRemovedByDriver':True,'additionalRemoved':removed,'releasedAllocatedKiB':sum(x['allocatedKiB'] for x in removed),'stablePayloadItems':len(manifest['files']),'stableMismatches':bad,'stableDeepStrictSignatureExit':0,'stablePid53592Alive':True,'remainingApps':apps,'remainingGeneratedDsyms':symbols,'newPackageArchiveSha256':sha(archive),'sdkCachesAndOldNewZIPsAndPrivateBackupsPreserved':True}
(raw/'cleanup.json').write_text(json.dumps(clean,ensure_ascii=False,indent=2)+'\n')
(ev/'.gitattributes').write_text('* -text -diff\n**/* -text -diff\n')
v={'date':'2026-10-22','frozenQASource':d['sourceCommit'],'productionCandidateSource':'5a509968400b2d140a69a02f89935c5db4e935ee','productionChanged':False,'sourceInputsVerified':len(d['inputSourceHashes']),'strictPreparationPhases':len(d['commands']),'CUAUIQuitProcesses':3,'automaticReopenCheckProcesses':3,'normalProcessExitsZero':6,'libraryClosesPerProcess':1,'portsClosedAfterAllExits':True,'forcedCleanup':False,'actualCloseHiddenWindowsByPublicCGWindowList':2,'dockOrStatusClickProven':False,'actualCUAGUIClassificationSavedAndReadOnlySQLCipherReopenVerified':True,'keychainUsed':False,'newOSPermissionPrompts':0,'physicalIMEOrVoiceOverProven':False,'finalOrdinaryZIPGUIProven':False,'issue46Criteria':[False,True,True,True,False,True],'issue48Criteria':[True,True,True,False,False,False],'issue50Criteria':[True,True,False,False,False,False],'raw':[{'path':p.relative_to(ev).as_posix(),'bytes':p.stat().st_size,'sha256':sha(p)} for p in sorted(raw.rglob('*')) if p.is_file()]}
(ev/'verification.json').write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n');print(json.dumps({'raw':len(v['raw']),'extraCleanedMiB':round(clean['releasedAllocatedKiB']/1024,1),'normalExits':6,'stablePayloadItems':len(manifest['files'])}))
