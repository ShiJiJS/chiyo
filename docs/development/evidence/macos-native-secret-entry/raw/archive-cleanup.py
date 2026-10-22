from pathlib import Path
import subprocess,json,hashlib,shutil,os,stat

root=Path.cwd();out=Path(__file__).resolve().parent
ev=root/'docs/development/evidence/macos-native-secret-entry';raw=ev/'raw'
raw.mkdir(parents=True,exist_ok=True)
assert subprocess.check_output(['git','branch','--show-current'],text=True).strip()=='codex/macos-adaptation'
product=['apps/desktop/lib/mac_secret_input.dart','apps/desktop/lib/credential_dialogs.dart','apps/desktop/lib/desktop_controls.dart','apps/desktop/macos/Runner/NativeSecretEditor.swift','apps/desktop/macos/Runner/MainFlutterWindow.swift','apps/desktop/macos/Runner.xcodeproj/project.pbxproj']
for name in product:
 assert (root/name).read_bytes()==(out/'source'/name).read_bytes(),name
for name in product+['apps/desktop/test/mac_secret_input_test.dart','apps/desktop/macos/Runner/NativeTextEditingMenu.swift']:
 dest=raw/'product-source'/name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(root/name,dest)
for name in ['apps/desktop/lib/secret_form_probe.dart','apps/desktop/test/native_secret_visual_probe_test.dart']:
 dest=raw/'qa-source'/name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(out/'source'/name,dest)
# Own build/test/supervisor logs, including unsuccessful iterations. Browser page bodies
# and installed tool guides are contextual reads, not public evidence to republish.
for p in out.iterdir():
 if p.is_file() and p.suffix in ['.py','.txt','.json','.md'] and not p.name.startswith(('ego-guide','issue')):
  shutil.copy2(p,raw/p.name)
shutil.copytree(out/'visual',raw/'visual',dirs_exist_ok=True)
assert 'No issues found!' in (out/'desktop-analysis-accepted.txt').read_text()
assert '+215 ~2: All tests passed!' in (out/'desktop-tests-accepted.txt').read_text()
for i in range(1,4):assert '+6: All tests passed!' in (out/f'regression-accepted-{i}.txt').read_text()
stages=json.loads((out/'build-stages.json').read_text());assert len(stages)==7 and all(x['exitCode']==0 for x in stages)
matrix=json.loads((out/'visual-matrix.json').read_text());assert matrix['sourceRestoredExact'] and all(x['exit']==0 for x in matrix['steps'])
phases=['first','focus','before-quit-routing','ready-quit','not-ready'];pids=[]
for phase in phases:
 assert json.loads((out/(phase+'-exit.json')).read_text())['exitCode']==0
 pids.append(json.loads((out/(phase+'-process.json')).read_text())['pid'])
assert len(set(pids))==5
log=(out/'before-quit-routing-runtime.txt').read_text()
for expected in ['QA_LIMIT unicodeExact=true empty=false','QA_LIMIT unicodeExact=false empty=true','version=1 createExact=true','version=2 createExact=false rotateExact=true']:assert expected in log
assert 'QA_QUIT forwarded' in (out/'ready-quit-runtime.txt').read_text()
ps=subprocess.check_output(['ps','-axo','pid,comm'],text=True)
assert not any(line.rstrip().endswith('/MacSecretEntryProbe') for line in ps.splitlines())
obs={'kind':'Actual CUA AX/screenshots observed during execution; transcribed observations, not saved native screenshots',
 'syntheticOnly':True,'uniqueProcesses':pids,'allProcessesExitedZero':True,
 'createRotate':{'actualForms':True,'repository':'MemoryInformationRepository','exactStoredSyntheticBytes':True,'versions':[1,2],'parentSaveRequired':True},
 'nativeSheet':{'secureRoleAndMaskedAXObserved':True,'mainFlutterTreeRetained':True,'copyCutDisabledObserved':True,'UTF8Over65536DoneDisabled':True,'maxTwoGraphemesRejectsABC':True,'twoComplexGraphemesAcceptedExact':True,'ReturnAcceptsValidDraft':True,'ReturnDoesNotAcceptInvalidDraft':True,'EscapeCancels':True,'clearDraftReturnsEmpty':True,'focusReturnsToSecretButton':True},
 'quit':{'preRoutingActiveSheetBlockedNormalQuit':True,'finalReadyCmdQForwardedThenExitedZero':True,'finalNotReadyCmdQExitedZero':True,'alternateQuitAndKeepWindowsTested':False},
 'finalQuitRouteChangeOnlyNativeWindow':True,'finalEditorDartAndSwiftSameAsCreateRotateRun':True,
 'visual':{'baseline':'9379dd5','themes':['purple','green','blue','mono'],'textScales':[1,2],'images':16,'contactSheetsViewed':2,'FlutterParentFormOnly':True},
 'keychainCalls':0,'newOSPermissionRequests':0,
 'limits':['Not an actual VoiceOver speech session','No ordinary persistent SQLCipher database acceptance','No Chinese IME acceptance','No Windows native test or CI','No clean-user Gatekeeper or notarization test','No full real-worker lifetime test','Native sheet uses system appearance, not Flutter four-theme styling']}
(raw/'actual-ui-observations.json').write_text(json.dumps(obs,ensure_ascii=False,indent=2)+'\n')
app=out/'source/apps/desktop/build/macos/Build/Products/Release/MacSecretEntryProbe.app'
sign=subprocess.run(['codesign','--verify','--deep','--strict',str(app)],capture_output=True,text=True);assert sign.returncode==0
reg='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
unreg=subprocess.run([reg,'-u',str(app)],capture_output=True,text=True);assert unreg.returncode==0
removed=[]
for d in [out/'source',root/'apps/desktop/build/native_assets',root/'apps/desktop/build/test_cache',root/'apps/desktop/build/unit_test_assets',root/'apps/desktop/.dart_tool/hooks_runner']:
 if not d.exists():continue
 assert not d.is_symlink()
 kb=int(subprocess.check_output(['du','-sk',str(d)],text=True).split()[0]);shutil.rmtree(d)
 removed.append({'path':str(d.relative_to(root)),'allocatedKiB':kb})
install=root/'local/中文 Mac 预览/AgentInfoManage';manifest=json.loads((install/'manifest.json').read_text());bad=[]
for e in manifest['files']:
 p=install/e['path']
 if 'link' in e:ok=p.is_symlink() and os.readlink(p)==e['link']
 else:ok=p.is_file() and not p.is_symlink() and p.stat().st_size==e['bytes'] and stat.S_IMODE(p.stat().st_mode)==e['mode'] and hashlib.sha256(p.read_bytes()).hexdigest()==e['sha256']
 if not ok:bad.append(e['path'])
sign=subprocess.run(['codesign','--verify','--deep','--strict',str(install/'app/info_desktop.app')],capture_output=True,text=True)
os.kill(53592,0);apps=[];dsyms=[]
for base in [root/'build/macos-adaptation',root/'local',root/'apps/desktop/build']:
 for folder,dirs,files in os.walk(base,followlinks=False):
  for name in dirs[:]:
   if name.endswith('.app') or name.endswith('.dSYM'):
    (apps if name.endswith('.app') else dsyms).append(str((Path(folder)/name).relative_to(root)));dirs.remove(name)
assert not bad and sign.returncode==0 and len(apps)==1 and not dsyms
clean={'unregisteredApp':str(app.relative_to(root)),'unregisterExit':unreg.returncode,'removed':removed,'releasedAllocatedKiB':sum(x['allocatedKiB'] for x in removed),'stableItemsVerified':len(manifest['files']),'stableMismatches':bad,'stableSignatureExit':sign.returncode,'stablePid53592Alive':True,'remainingApps':apps,'remainingGeneratedDsyms':dsyms,'sdksZIPsBackupsRecoveryKeysPreserved':True}
(raw/'cleanup.json').write_text(json.dumps(clean,ensure_ascii=False,indent=2)+'\n')
(ev/'.gitattributes').write_text('* -text -diff\n**/* -text -diff\n')
v={'date':'2026-10-22','sourceBase':'9379dd5d43e036a74fafde17a83f08b32a2165d6','productionSecureEntryIntegrated':True,'sixProductionFilesExactQASource':True,'analysisExit':0,'desktopTestsPassed':215,'desktopTestsSkipped':2,'targetedRegressionRuns':3,'testsPerRegressionRun':6,'countsNotAddedTogether':True,'releaseBuildStagesPassed':7,'finalStrictSignatureExit':0,'uniqueFixtureProcessesExitedZero':5,'visualBaselineAndCurrentRunsExitZero':True,'keychainCalls':0,'newOSPermissionRequests':0,'ordinaryPreviewSource':'4690e79357bb728da22193d8dadd6dc8a8ce2ce6','existingZIPSource':'f93c3bd','ordinaryPreviewAndZIPContainThisChange':False,'issue48Criteria':[True,True,True,False,False,False],'issue50Criteria':[True,True,False,False,False,False],**clean}
v['files']=[{'path':str(p.relative_to(ev)),'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(raw.rglob('*')) if p.is_file()]
(ev/'verification.json').write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'archivedFiles':len(v['files']),**clean},ensure_ascii=False,indent=2))
