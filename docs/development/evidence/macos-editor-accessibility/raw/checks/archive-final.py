from pathlib import Path
import hashlib,json,shutil,subprocess
r=Path.cwd();b=r/'build/macos-adaptation/issue48-voiceover-20261022';base=r/'docs/development/evidence/macos-editor-accessibility';sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
for num,folder in [(5,'interrupted-timeout'),(6,'final-scroll-position')]:
 run=b/f'run-{num}';d=json.loads((run/'result.json').read_text());raw=base/'raw'/folder;raw.mkdir(parents=True,exist_ok=True)
 assert d['ownedPrivateTargetsAndGeneratedAppRemoved'] and d['unregisterExitCode']==0
 if num==6:
  assert d['complete'] and not d.get('failure') and not d.get('forcedFailureCleanup')
  assert len(d['cases'])==2 and all(x['exitCode']==0 for x in d['processExits'])
  assert all(x['libraryCloses']==1 and x['flutterErrors']==0 and x['portClosedAfterExit'] for x in d['cases'])
 else:assert not d['complete'] and d['forcedFailureCleanup'] and d['failure']=='AssertionError: Actual UI deadline'
 for n,h in d['inputSourceHashes'].items():
  assert sha(r/n)==h,n
  if n not in d['copyModifications']:assert (run/'source'/n).read_bytes()==(r/n).read_bytes(),n
 for n,h in d['copyModifications'].items():assert sha(run/'source'/n)==h
 for p in run.glob('*.json'):shutil.copy2(p,raw/p.name)
 shutil.copytree(run/'logs',raw/'logs',dirs_exist_ok=True)
 for n in ['scripts/qa/macos-editor-focus-ui.py','apps/desktop/integration_test/macos_editor_focus_manual.dart','apps/desktop/lib/information_editor.dart','apps/desktop/test/information_editor_semantics_test.dart','apps/desktop/lib/mac_text_field_accessibility.dart','apps/desktop/test/mac_text_field_accessibility_test.dart','apps/desktop/macos/Runner/NativeTextFieldAccessibility.swift','scripts/qa/macos-text-field-accessibility-test.swift']:
  shutil.copy2(r/n,raw/Path(n).name)
 for n in d['copyModifications']:
  p=raw/'qa-copy'/n;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(run/'source'/n,p)
 notes={'source':d['sourceCommit'],'complete':num==6,'automaticScrollRefreshWithoutEditingPassed':num==6,'normalCommandQProcesses':2 if num==6 else 0,'VoiceOverEnabled':False,'checkpointWasPastedNotIME':num==6,'nativeIMEThisRunPassed':False,'note': 'run5 interrupted turn exceeded actual UI deadline; forced failure cleanup, not a pass' if num==5 else 'Top name/description, middle structured field name/value/description, partially visible attachment name and bottom attachment description labels observed after actual scrollbar moves without editing. File panel opened; Escape alone did not dismiss via CUA; actual Cancel button closed. Chinese pasted, saved, readonly SQL verified before/after independent process reopening. BaselineValue and 7-byte attachment preserved. CUA IME nihao had composing [-1,-1], not credited.'}
 (raw/'cua-observations.json').write_text(json.dumps(notes,ensure_ascii=False,indent=2)+'\n')
 assert str(run/'source') not in subprocess.check_output(['ps','-axo','pid,comm'],text=True)
 p=run/'source';assert p.is_dir() and not p.is_symlink();kb=int(subprocess.check_output(['du','-sk',str(p)],text=True).split()[0]);shutil.rmtree(p)
 (raw/'cleanup.json').write_text(json.dumps({'sourceInputsVerified':len(d['inputSourceHashes']),'sourceCommit':d['sourceCommit'],'sourceRemoved':True,'releasedAllocatedKiB':kb,'appAndPrivateFixturesAlreadyRemovedByDriver':True},indent=2)+'\n')
 print(folder,len(d['inputSourceHashes']),kb)
raw=base/'raw'/'checks';raw.mkdir(parents=True,exist_ok=True)
for p in b.iterdir():
 if p.is_file() and p.suffix in ['.txt','.json','.py','.swift'] and not p.name.startswith(('ego-','issue48-')):shutil.copy2(p,raw/p.name)
for name in ['read-voiceover','native-accessibility-compile.dylib','native-accessibility-test','native-accessibility-test-v2','qa-native-labels-diagnostic.dylib']:
 p=b/name
 if p.exists():assert p.is_file() and not p.is_symlink();p.unlink()
print('archived-and-cleaned')
