from pathlib import Path
import sys,json,hashlib,shutil,subprocess,io,tarfile
r=Path.cwd();b=r/'build/macos-adaptation/issue48-field-purposes-20261022';num=int(sys.argv[1]);run=b/f'native-run-{num}';d=json.loads((run/'result.json').read_text());raw=b/'evidence/raw'/({1:'intermediate-hidden-pages',2:'partial-visible-pages',3:'final-save-reopen'}[num]);raw.mkdir(parents=True,exist_ok=True)
assert not d.get('forcedFailureCleanup') and d['ownedPrivateTargetsAndGeneratedAppRemoved'] and d['unregisterExitCode']==0
if num==2:
 assert not d['complete'] and d.get('failure') and len(d['processExits'])==1 and d['processExits'][0]['exitCode']==0
 last=json.loads((run/'last-edit.json').read_text());assert last['libraryCloses']==1 and last['flutterErrors']==0
 import socket
 with socket.socket() as sock:
  sock.settimeout(1);assert sock.connect_ex(('127.0.0.1',last['port']))!=0
 (raw/'partial-port-closed.json').write_text(json.dumps({'port':last['port'],'closedAfterNormalQuit':True,'saveReopenComplete':False})+'\n')
else:
 assert d['complete'] and not d.get('failure')
 assert len(d['cases'])==2 and all(x['exitCode']==0 for x in d['processExits'])
 assert all(x['libraryCloses']==1 and x['flutterErrors']==0 and x['portClosedAfterExit'] for x in d['cases'])
a=tarfile.open(fileobj=io.BytesIO(subprocess.check_output(['git','archive',d['sourceCommit'],'apps/desktop','packages','scripts','integrations','third_party'])))
sha=lambda data:hashlib.sha256(data).hexdigest()
for n,h in d['inputSourceHashes'].items():
 data=a.extractfile(n).read();assert sha(data)==h,n
 if n not in d['copyModifications']:assert (run/'source'/n).read_bytes()==data,n
for n,h in d['copyModifications'].items():assert sha((run/'source'/n).read_bytes())==h
for p in run.glob('*.json'):shutil.copy2(p,raw/p.name)
shutil.copytree(run/'logs',raw/'logs',dirs_exist_ok=True)
for n in ['scripts/qa/macos-editor-focus-ui.py','apps/desktop/integration_test/macos_editor_focus_manual.dart','apps/desktop/lib/mac_text_field_accessibility.dart','apps/desktop/test/mac_text_field_accessibility_test.dart','apps/desktop/test/field_purposes_test.dart']:
 (raw/Path(n).name).write_bytes(a.extractfile(n).read())
for n in d['copyModifications']:
 p=raw/'qa-copy'/n;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(run/'source'/n,p)
notes={'allWorkflowNativeLabelsPassed':False,'saveReopenComplete':num!=2,'checkpointPasted':True,'fullIMEOrVoiceOverClaimed':False,'nativeFailure': 'Retained IndexedStack pages kept hidden descriptors; similar/duplicate geometries made later search/credential labels ambiguous or updates rejected' if num==1 else None,'normalCommandQProcesses':d['processExits'],'scopeLimit': 'Template native editor/full AX/VoiceOver still pending; CUA cached tree differed from screenshot and coordinate click failed' if num==2 else ('Current source save/reopen check only, not all forms' if num==3 else 'Intermediate native label failure retained')}
(raw/'cua-observations.json').write_text(json.dumps(notes,ensure_ascii=False,indent=2)+'\n')
p=run/'source';assert p.is_dir() and not p.is_symlink() and str(p) not in subprocess.check_output(['ps','-axo','pid,comm'],text=True);kb=int(subprocess.check_output(['du','-sk',str(p)],text=True).split()[0]);shutil.rmtree(p)
(raw/'cleanup.json').write_text(json.dumps({'sourceCommit':d['sourceCommit'],'inputFilesVerifiedAgainstGit':len(d['inputSourceHashes']),'copyModificationsVerified':True,'removedSourceAllocatedKiB':kb,'sourceRemoved':True},indent=2)+'\n');print(json.dumps({'run':num,'source':d['sourceCommit'],'files':len(d['inputSourceHashes']),'removedMiB':kb/1024}))
