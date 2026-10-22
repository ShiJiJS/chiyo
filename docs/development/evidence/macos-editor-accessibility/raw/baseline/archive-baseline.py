from pathlib import Path
import json,hashlib,shutil,subprocess
r=Path.cwd();b=r/'build/macos-adaptation/issue48-voiceover-20261022';run=b/'run-1';ev=r/'docs/development/evidence/macos-editor-accessibility';raw=ev/'raw/baseline';raw.mkdir(parents=True,exist_ok=True);sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();d=json.loads((run/'result.json').read_text())
assert d['complete'] and d['ownedPrivateTargetsAndGeneratedAppRemoved'] and d['unregisterExitCode']==0 and not d.get('failure') and not d.get('forcedFailureCleanup')
assert len(d['cases'])==2 and all(x['exitCode']==0 for x in d['processExits']) and all(x['libraryCloses']==1 and x['flutterErrors']==0 and x['portClosedAfterExit'] for x in d['cases'])
for n,h in d['inputSourceHashes'].items():
 assert sha(r/n)==h,n
 if n not in d['copyModifications']:assert (run/'source'/n).read_bytes()==(r/n).read_bytes(),n
for n,h in d['copyModifications'].items():assert sha(run/'source'/n)==h
for p in run.glob('*.json'):
 assert p.name!='controller.json';shutil.copy2(p,raw/p.name)
shutil.copytree(run/'logs',raw/'logs',dirs_exist_ok=True)
for n in ['scripts/qa/macos-editor-focus-ui.py','apps/desktop/integration_test/macos_editor_focus_manual.dart','apps/desktop/lib/information_editor.dart']:
 shutil.copy2(r/n,raw/Path(n).name)
for n in d['copyModifications']:
 p=raw/'qa-copy'/n;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(run/'source'/n,p)
for n in ['voiceover-before.json','voiceover-after-shortcut.json','voiceover-enabled.json','voiceover-after-welcome.json','voiceover-restored.json','read-voiceover.swift']:
 shutil.copy2(b/n,raw/n)
shutil.copy2(__file__,raw/'archive-baseline.py')
notes={'VoiceOverInitial':False,'CommandF5ViaCUAEnabledVoiceOver':False,'actualSystemSettingsToggle':'Actual Accessibility > VoiceOver toggle off→on; welcome Use VoiceOver; display-welcome preference remained1','NSWorkspaceIsVoiceOverEnabledAfterWelcome':True,'actualVoiceOverPid':33953,'realVoiceOverCursorNavigationProven':False,'controlOptionRightObservation':'No confirmed VoiceOver navigation; product focusKeys changed to inbox-filter-all','VoiceOverCaptionObservation':'Caption panel preference already on; core VoiceOver CUA binding timed out, scrod not valid app; no speech/caption result claimed','AXFormBaseline':'Separate static labels; seven text fields have no purpose label; empty tags button has no label; directory button only says 未分类','actualCUAEditing':'BaselineDescription replaced by MacVoiceOverSaved and actual Save; normal CommandQ; independently reopened same synthetic library; actual CommandQ','VoiceOverAfter':False,'systemSettingsRestored':'Notification page selected; no notification preference changed','voiceOverUtilityClosed':True,'newSecurityPermissionRequests':0,'keychainUsed':False}
(raw/'cua-observations.json').write_text(json.dumps(notes,ensure_ascii=False,indent=2)+'\n')
assert str(run/'source') not in subprocess.check_output(['ps','-axo','pid,comm'],text=True)
p=run/'source';assert p.is_dir() and not p.is_symlink();kb=int(subprocess.check_output(['du','-sk',str(p)],text=True).split()[0]);shutil.rmtree(p)
(raw/'cleanup.json').write_text(json.dumps({'sourceInputsVerified':len(d['inputSourceHashes']),'sourceCommit':d['sourceCommit'],'remainingSourceRemoved':True,'releasedAllocatedKiB':kb,'appAndPrivateFixturesAlreadyRemovedByDriver':True},indent=2)+'\n');(ev/'.gitattributes').write_text('* -text -diff\n**/* -text -diff\n');print(json.dumps({'baselineSource':d['sourceCommit'],'verifiedInputs':len(d['inputSourceHashes']),'sourceRemovedMiB':round(kb/1024,1)}))
