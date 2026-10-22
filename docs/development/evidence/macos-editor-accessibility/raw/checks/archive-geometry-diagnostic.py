from pathlib import Path
import json,hashlib,shutil,subprocess
r=Path.cwd();b=r/'build/macos-adaptation/issue48-voiceover-20261022';run=b/'run-4';raw=r/'docs/development/evidence/macos-editor-accessibility/raw/geometry-diagnostic';raw.mkdir(parents=True,exist_ok=True);sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();d=json.loads((run/'result.json').read_text())
assert d['complete'] and d['ownedPrivateTargetsAndGeneratedAppRemoved'] and d['unregisterExitCode']==0 and not d.get('failure') and not d.get('forcedFailureCleanup')
assert len(d['cases'])==2 and all(x['exitCode']==0 for x in d['processExits']) and all(x['libraryCloses']==1 and x['flutterErrors']==0 and x['portClosedAfterExit'] for x in d['cases'])
for n,h in d['inputSourceHashes'].items():
 assert sha(r/n)==h,n
 if n not in d['copyModifications']:assert (run/'source'/n).read_bytes()==(r/n).read_bytes(),n
for n,h in d['copyModifications'].items():assert sha(run/'source'/n)==h
for p in run.glob('*.json'):
 assert p.name!='controller.json';shutil.copy2(p,raw/p.name)
shutil.copytree(run/'logs',raw/'logs',dirs_exist_ok=True)
for n in ['scripts/qa/macos-editor-focus-ui.py','apps/desktop/integration_test/macos_editor_focus_manual.dart','apps/desktop/lib/information_editor.dart','apps/desktop/test/information_editor_semantics_test.dart','apps/desktop/lib/mac_text_field_accessibility.dart','apps/desktop/macos/Runner/NativeTextFieldAccessibility.swift']:
 shutil.copy2(r/n,raw/Path(n).name)
for n in d['copyModifications']:
 p=raw/'qa-copy'/n;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(run/'source'/n,p)
shutil.copy2(__file__,raw/'archive-intermediate.py')
notes={'source': '69a7b8d', 'scope': 'Diagnostic: metadata stayed at initial locations after actual scrollbar move', 'topNativeLabels': ['信息名称', '公开说明'], 'nativeScrollRefreshPassed': False, 'passiveGeometryLog': 'NATIVE_FIELD_GEOMETRY records purposes and rectangles only; no text values, input callbacks or focus commands', 'directObservedDifference': 'Visible native field frames move after scroll while labels list remains the two initial top-field rectangles; later an edit refreshes metadata', 'AXFrameIsNotViewFrame': 'Observed AppKit AX cell frame has different insets/dimensions from live view frame; do not infer stale AX cache from this alone', 'checkpointWasPastedNotIME': True, 'normalCommandQProcesses': 2, 'VoiceOverEnabled': False, 'nextStep': 'Track concrete ScrollPosition replacements, then verify automatic refresh without editing'}
(raw/'cua-observations.json').write_text(json.dumps(notes,ensure_ascii=False,indent=2)+'\n')
assert str(run/'source') not in subprocess.check_output(['ps','-axo','pid,comm'],text=True)
p=run/'source';assert p.is_dir() and not p.is_symlink();kb=int(subprocess.check_output(['du','-sk',str(p)],text=True).split()[0]);shutil.rmtree(p)
(raw/'cleanup.json').write_text(json.dumps({'sourceInputsVerified':len(d['inputSourceHashes']),'sourceCommit':d['sourceCommit'],'sourceRemoved':True,'releasedAllocatedKiB':kb,'appAndPrivateFixturesAlreadyRemovedByDriver':True},indent=2)+'\n');print(json.dumps({'source':d['sourceCommit'],'verifiedInputs':len(d['inputSourceHashes']),'automaticScrollRefreshProven':False,'sourceRemovedMiB':round(kb/1024,1)}))
