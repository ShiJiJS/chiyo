from pathlib import Path
import sys,json,hashlib,shutil,subprocess,io,tarfile
r=Path.cwd();b=r/'build/macos-adaptation/issue48-focus-alignment-20261022';name=sys.argv[1];run=b/name;d=json.loads((run/'result.json').read_text());raw=b/'evidence/raw'/name;raw.mkdir(parents=True,exist_ok=True)
assert d['observationOnly'] and d['complete'] and not d.get('failure') and not d.get('forcedFailureCleanup') and d['ownedPrivateTargetsAndGeneratedAppRemoved'] and d['unregisterExitCode']==0
assert len(d['cases'])==1 and len(d['processExits'])==1 and d['processExits'][0]['exitCode']==0
assert d['cases'][0]['observationOnly'] and d['cases'][0]['observationFinishedByNormalClose'] and d['cases'][0]['libraryCloses']==1 and d['cases'][0]['flutterErrors']==0 and d['cases'][0]['portClosedAfterExit']
a=tarfile.open(fileobj=io.BytesIO(subprocess.check_output(['git','archive',d['sourceCommit'],'apps/desktop','packages','scripts','integrations','third_party'])));sha=lambda data:hashlib.sha256(data).hexdigest()
for n,h in d['inputSourceHashes'].items():
 data=a.extractfile(n).read();assert sha(data)==h,n
 if n not in d['copyModifications']:assert (run/'source'/n).read_bytes()==data,n
for n,h in d['copyModifications'].items():assert sha((run/'source'/n).read_bytes())==h,n
for p in run.glob('*.json'):shutil.copy2(p,raw/p.name)
for folder in ['logs','stages']:
 if (run/folder).is_dir():shutil.copytree(run/folder,raw/folder,dirs_exist_ok=True)
for n in ['scripts/qa/macos-editor-focus-ui.py','apps/desktop/integration_test/macos_editor_focus_manual.dart','apps/desktop/lib/prototype_dialog.dart']:(raw/Path(n).name).write_bytes(a.extractfile(n).read())
for n in d['copyModifications']:
 p=raw/'qa-copy'/n;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(run/'source'/n,p)
errors=[x for x in (run/'logs/edit.txt').read_text().splitlines() if 'Failed to update ui::AXTree' in x];(raw/'native-ax-errors.json').write_text(json.dumps({'count':len(errors),'errors':errors,'normalQuitDoesNotMeanAXPassed':True},indent=2)+'\n')
p=run/'source';assert p.is_dir() and not p.is_symlink() and str(p) not in subprocess.check_output(['ps','-axo','pid,comm'],text=True);kb=int(subprocess.check_output(['du','-sk',str(p)],text=True).split()[0]);shutil.rmtree(p)
(raw/'cleanup.json').write_text(json.dumps({'sourceCommit':d['sourceCommit'],'inputFilesVerifiedAgainstGit':len(d['inputSourceHashes']),'copyModificationsVerified':True,'removedSourceAllocatedKiB':kb,'sourceRemoved':True,'observationOnlyNoSaveReopenClaim':True},indent=2)+'\n');print(json.dumps({'run':name,'source':d['sourceCommit'],'files':len(d['inputSourceHashes']),'nativeAXErrors':len(errors),'normalProcessExit':d['processExits'][0]['exitCode']}))
