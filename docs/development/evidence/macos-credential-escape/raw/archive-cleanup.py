from pathlib import Path
import json,hashlib,shutil,subprocess,os,stat

root=Path.cwd();work=root/'build/macos-adaptation'
base=work/'issue48-keyboard-c6958da-20261022';final=work/'issue48-credential-escape-fixed-20261022'
ev=root/'docs/development/evidence/macos-credential-escape';raw=ev/'raw';raw.mkdir(parents=True,exist_ok=True)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
assert subprocess.check_output(['git','branch','--show-current'],text=True).strip()=='codex/macos-adaptation'
states={}
for phase,out in [('baseline',base),('fixed',final)]:
 state=json.loads((out/'result.json').read_text());states[phase]=state
 assert state['complete'] and not state.get('forcedFailureCleanup') and not state.get('failure')
 assert len(state['commands'])==8 and all(x['exitCode']==0 for x in state['commands'])
 assert len(state['processExits'])==2 and all(x['exitCode']==0 for x in state['processExits'])
 assert state['ownedPrivateTargetsAndGeneratedAppRemoved'] and state['unregisterExitCode']==0
 assert not (out/'controller.json').exists()
 assert len(state['inputSourceHashes'])==(644 if phase=='baseline' else 645)
 for name,digest in state['inputSourceHashes'].items():
  if phase=='baseline':
   b=subprocess.check_output(['git','show',state['sourceCommit']+':'+name]);assert hashlib.sha256(b).hexdigest()==digest,name
  else:assert sha(root/name)==digest,name
  expected=state['copyModifications'].get(name,digest)
  assert sha(out/'source'/name)==expected,name
  if name not in state['copyModifications']:continue
  target=raw/phase/'qa-source'/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(out/'source'/name,target)
 dest=raw/phase;dest.mkdir(exist_ok=True)
 shutil.copytree(out/'logs',dest/'logs',dirs_exist_ok=True)
 for p in out.iterdir():
  if p.is_file() and p.suffix in ['.py','.txt','.json'] and not p.name.startswith(('ego-guide','issue')):
   shutil.copy2(p,dest/p.name)
 name='apps/desktop/integration_test/macos_editor_focus_manual.dart'
 target=dest/'qa-source'/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(out/'source'/name,target)
 for name in ['apps/desktop/lib/credential_dialogs.dart','apps/desktop/lib/credential_management.dart']:
  target=dest/'product-source'/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(out/'source'/name,target)
 for case in state['cases']:
  assert case['complete'] and case['otherFieldsAndAttachmentPreserved'] and case['libraryCloses']==1 and case['flutterErrors']==0 and case['portClosedAfterExit']
 for p in out.glob('storage-*.json'):
  d=json.loads(p.read_text());assert d['sqliteReadOnly'] and d['dbAndWalHashesUnchanged'] and all(d['knownSyntheticBytesExact'])
assert 'Some tests failed.' in (base/'escape-regression-before.txt').read_text()
assert '+2 -4:' in (base/'escape-regression-before.txt').read_text()
assert '+6: All tests passed!' in (base/'escape-regression-after.txt').read_text()
assert '+221 ~2: All tests passed!' in (base/'desktop-tests-final.txt').read_text()
assert 'No issues found!' in (base/'desktop-analysis-final.txt').read_text()
assert 'qaKeyMonitor' in (base/'source/apps/desktop/macos/Runner/MainFlutterWindow.swift').read_text()
assert 'qaKeyMonitor' not in (final/'source/apps/desktop/macos/Runner/MainFlutterWindow.swift').read_text()
for n in ['apps/desktop/lib/credential_dialogs.dart','apps/desktop/lib/credential_management.dart','apps/desktop/test/credential_keyboard_test.dart']:
 assert (final/'source'/n).read_bytes()==(root/n).read_bytes()
 p=raw/'final-product'/n;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(root/n,p)
shutil.copy2(root/'scripts/qa/macos-editor-focus-ui.py',raw/'supervisor.py')
(raw/'production.patch').write_text(subprocess.check_output(['git','diff','HEAD','--','apps/desktop/lib/credential_dialogs.dart','apps/desktop/lib/credential_management.dart'],text=True))
shutil.copy2(__file__,raw/'archive-cleanup.py')
ps=subprocess.check_output(['ps','-axo','pid,comm'],text=True)
for state in states.values():
 for item in state['processExits']:
  assert not any(line.strip().split()[0]==str(item['pid']) for line in ps.splitlines() if line.strip())
removed=[]
for p in [base/'source',final/'source',root/'apps/desktop/build/native_assets',root/'apps/desktop/build/test_cache',root/'apps/desktop/build/unit_test_assets',root/'apps/desktop/.dart_tool/hooks_runner']:
 if not p.exists():continue
 assert not p.is_symlink()
 kb=int(subprocess.check_output(['du','-sk',str(p)],text=True).split()[0]);shutil.rmtree(p)
 removed.append({'path':str(p.relative_to(root)),'allocatedKiB':kb})
install=root/'local/中文 Mac 预览/AgentInfoManage';m=json.loads((install/'manifest.json').read_text());bad=[]
for e in m['files']:
 p=install/e['path']
 if 'link' in e:ok=p.is_symlink() and os.readlink(p)==e['link']
 else:ok=p.is_file() and not p.is_symlink() and p.stat().st_size==e['bytes'] and stat.S_IMODE(p.stat().st_mode)==e['mode'] and sha(p)==e['sha256']
 if not ok:bad.append(e['path'])
r=subprocess.run(['codesign','--verify','--deep','--strict',str(install/'app/info_desktop.app')],capture_output=True,text=True)
os.kill(53592,0);apps=[];symbols=[]
for area in [work,root/'local',root/'apps/desktop/build']:
 for folder,dirs,files in os.walk(area,followlinks=False):
  for n in dirs[:]:
   p=Path(folder)/n
   if p.is_symlink():dirs.remove(n)
   elif n.endswith('.app') or n.endswith('.dSYM'):
    (apps if n.endswith('.app') else symbols).append(str(p.relative_to(root)));dirs.remove(n)
assert not bad and r.returncode==0 and len(apps)==1 and not symbols
clean={'removed':removed,'releasedAllocatedKiB':sum(x['allocatedKiB'] for x in removed),'stableItemsVerified':len(m['files']),'stableMismatches':bad,'stableSignatureExit':r.returncode,'stablePid53592Alive':True,'remainingApps':apps,'remainingGeneratedDsyms':symbols,'sdksZIPsBackupsRecoveryKeysPreserved':True}
(raw/'cleanup.json').write_text(json.dumps(clean,ensure_ascii=False,indent=2)+'\n')
(ev/'.gitattributes').write_text('* -text -diff\n**/* -text -diff\n')
v={'date':'2026-10-22','sourceBase':'df8d565e8f60b936d35098684f6050b9e410a144','productionFilesChanged':['apps/desktop/lib/credential_dialogs.dart','apps/desktop/lib/credential_management.dart'],'newTests':6,'baselineTargetedTestsPassed':2,'baselineTargetedTestsFailed':4,'finalTargetedTestsPassed':6,'desktopTestsPassed':221,'desktopTestsSkipped':2,'countsNotAddedTogether':True,'strictAnalysisExit':0,'sourceInputsVerified':{'baseline':644,'fixed':645},'nativeBuildPhasesPerRound':8,'actualAppProcessesExitedZero':4,'baselineRoundCompleteIsNotEscapePass':True,'fixedNativeKeyboardDiagnosticBindingUsed':False,'credentialCreateRotateSQLCipherBytesAndReopenVerified':True,'ordinaryPreviewSource':'4690e79357bb728da22193d8dadd6dc8a8ce2ce6','currentCandidateSource':'c6958daabcd77862f436db5088e08bb0bf3fa6b4','candidateContainsThisEscapeFix':False,'keychainCalls':0,'newOSPermissionRequests':0,'physicalShiftTabVerified':False,'IMEVerified':False,'issue48Criteria':[True,True,True,False,False,False],'issue50Criteria':[True,True,False,False,False,False],**clean}
v['files']=[{'path':str(p.relative_to(ev)),'bytes':p.stat().st_size,'sha256':sha(p)} for p in sorted(raw.rglob('*')) if p.is_file()]
(ev/'verification.json').write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'rawFiles':len(v['files']),**clean},ensure_ascii=False,indent=2))
