from pathlib import Path
import subprocess,shutil,json,hashlib,os,stat
root=Path.cwd();out=Path(__file__).resolve().parent;ev=root/'docs/development/evidence/macos-editing-menu-state';raw=ev/'raw';raw.mkdir(parents=True,exist_ok=True)
names=['prepared.json','prepare.py','run.py','build.py','build-run.txt','build-run-2.txt','build-run-3.txt','build-stages.json','build-probe.txt','analyze-probe.txt','format-probe.txt','pub-core.txt','pub-cli.txt','pub-storage.txt','pub-desktop.txt','regression-before.txt','regression-before-actual.txt','regression-after.txt','regression-delete-draft.txt','regression-final.txt','desktop-analysis.txt','desktop-analysis-final.txt','desktop-analysis-accepted.txt','desktop-tests.txt','desktop-tests-final.txt','first-NativeTextEditingMenu.swift']
for phase in ['first','second','fixed']:
 for suffix in ['runtime.txt','process.json','exit.json','signature.txt']:
  p=out/(phase+'-'+suffix)
  if p.exists():names.append(p.name)
for n in names:shutil.copy2(out/n,raw/n)
for name in ['apps/desktop/lib/mac_text_editing.dart','apps/desktop/macos/Runner/NativeTextEditingMenu.swift','apps/desktop/test/mac_editing_menu_state_test.dart','apps/desktop/test/mac_text_editing_test.dart','apps/desktop/lib/window_frame.dart']:
 p=raw/'sources'/name;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(root/name,p)
for name in ['apps/desktop/lib/clipboard_probe.dart','apps/desktop/macos/Runner/MainFlutterWindow.swift','apps/desktop/macos/Runner/NativeTextEditingMenu.swift','apps/desktop/macos/Runner/Configs/AppInfo.xcconfig']:
 p=raw/'qa-source'/name;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(out/'source'/name,p)
qa=(out/'source/apps/desktop/macos/Runner/NativeTextEditingMenu.swift').read_text();prod=(root/'apps/desktop/macos/Runner/NativeTextEditingMenu.swift').read_text()
for line in ['    print("QA_MENU request"); fflush(stdout)\n','      print("QA_MENU state \\(state)"); fflush(stdout)\n']:qa=qa.replace(line,'')
assert qa==prod
assert (out/'source/apps/desktop/lib/mac_text_editing.dart').read_bytes()==(root/'apps/desktop/lib/mac_text_editing.dart').read_bytes()
qa=(out/'source/apps/desktop/macos/Runner/MainFlutterWindow.swift').read_text();a=qa.index('    // QA-only: preserve all original pasteboard item types in native memory.');b=qa.index('    super.awakeFromNib()',a);assert qa[:a]+qa[b:]==(root/'apps/desktop/macos/Runner/MainFlutterWindow.swift').read_text()
(raw/'source-matches.json').write_text(json.dumps({'dartBridgeExact':True,'nativeBridgeExactExceptTwoQaBooleanLogLines':True,'mainWindowExactExceptAuditedMemoryOnlyClipboardFixture':True},indent=2)+'\n')
(raw/'production.patch').write_bytes(subprocess.check_output(['git','diff','--','apps/desktop/lib/mac_text_editing.dart','apps/desktop/macos/Runner/NativeTextEditingMenu.swift']))
observations={'kind':'Actual CUA AX/screenshots transcribed; no separate screenshot set','first':{'pid':94057,'menusStayedDisabled':True,'noTrackingNotificationLogObserved':True,'exitCode':0},'second':{'pid':94661,'validationDrivenQueryWorkedAfterAsyncRefresh':True,'emptyPasteOnlyEnabled':True,'selectedCopyCutEnabled':True,'readOnlyCopyOnlyEnabled':True,'legacyDeleteStillEnabledReadOnly':True,'exitCode':0},'final':{'pid':95562,'selectionMenuDeleteClearedFlutterModel':True,'menuUndoRestoredAsciiExact':True,'menuRedoClearedModel':True,'readonlySelected':{'copy':True,'cut':False,'paste':False,'deleteSelection':False,'undo':False,'redo':False},'obscuredSelected':{'copy':False,'cut':False,'paste':True,'deleteSelection':True},'obscuredCopyShortcutDidNotOverwriteSyntheticClipboard':True,'pasteAfterBlockedCopyReachedChineseFixture':True,'nativeSavePanel':{'deleteFilenameEmptiedAndDisabledSave':True,'nativeUndoRestoredNameAndEnabledSave':True,'nativeRedoEmptiedAndDisabledSave':True,'cancelled':True,'fileSaved':False,'flutterModelRemainedAsciiUntilExplicitPaste':True},'visualObscuredFieldShowedDots':True,'axSometimesReturnedKnownPlainSyntheticValueDespiteObscuredTrue':True,'obscuredAccessibilityPrivacyAccepted':False,'exitCode':0},'limits':['Snapshots update asynchronously; first AX read can contain previous or disabled state until Flutter reply','No blanket accessibility privacy acceptance; masked field AX/plaintext discrepancy remains to investigate','No physical IME or ordinary installed-package upgrade acceptance','Other AppKit commands such as spelling/transformations are not covered'],'keychainCalls':0,'newOSPermissionRequests':0}
(raw/'actual-ui-observations.json').write_text(json.dumps(observations,ensure_ascii=False,indent=2)+'\n')
ps=subprocess.check_output(['ps','-axo','pid,comm'],text=True);assert not any(x.rstrip().endswith('/MacMenuStateProbe') for x in ps.splitlines())
for phase in ['first','second','fixed']:
 assert json.loads((out/(phase+'-exit.json')).read_text())['exitCode']==0
 assert 'QA_CLIPBOARD restored original item types' in (out/(phase+'-runtime.txt')).read_text()
app=out/'source/apps/desktop/build/macos/Build/Products/Release/MacMenuStateProbe.app';reg='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister';r=subprocess.run([reg,'-u',str(app)],capture_output=True,text=True);assert r.returncode==0;(raw/'unregister.txt').write_text(r.stdout+r.stderr)
removed=[]
for d in [out/'source',root/'apps/desktop/build/native_assets',root/'apps/desktop/build/test_cache',root/'apps/desktop/build/unit_test_assets',root/'apps/desktop/.dart_tool/hooks_runner']:
 if d.exists():
  assert not d.is_symlink();kb=int(subprocess.check_output(['du','-sk',str(d)],text=True).split()[0]);shutil.rmtree(d);removed.append({'path':str(d.relative_to(root)),'allocatedKiB':kb})
install=root/'local/中文 Mac 预览/AgentInfoManage';m=json.loads((install/'manifest.json').read_text());bad=[]
for e in m['files']:
 p=install/e['path']
 if 'link' in e:ok=p.is_symlink() and os.readlink(p)==e['link']
 else:ok=p.is_file() and not p.is_symlink() and p.stat().st_size==e['bytes'] and stat.S_IMODE(p.stat().st_mode)==e['mode'] and hashlib.sha256(p.read_bytes()).hexdigest()==e['sha256']
 if not ok:bad.append(e['path'])
r=subprocess.run(['codesign','--verify','--deep','--strict',str(install/'app/info_desktop.app')],capture_output=True,text=True);os.kill(53592,0);apps=[];dsyms=[]
for base in [root/'build/macos-adaptation',root/'local',root/'apps/desktop/build']:
 for folder,dirs,files in os.walk(base,followlinks=False):
  for name in dirs[:]:
   if name.endswith('.app') or name.endswith('.dSYM'):
    (apps if name.endswith('.app') else dsyms).append(str((Path(folder)/name).relative_to(root)));dirs.remove(name)
assert bad==[] and r.returncode==0 and len(apps)==1 and dsyms==[]
cleanup={'removed':removed,'releasedAllocatedKiB':sum(x['allocatedKiB'] for x in removed),'stableItemsVerified':len(m['files']),'stableMismatches':bad,'stableSignatureExit':r.returncode,'stablePid53592Alive':True,'remainingApps':apps,'remainingGeneratedDsyms':dsyms,'originalZIPsAndPrivateBackupsRetained':True};(raw/'cleanup.json').write_text(json.dumps(cleanup,ensure_ascii=False,indent=2)+'\n')
shutil.copy2(__file__,raw/'archive-cleanup.py')
(ev/'.gitattributes').write_text('* -text -diff\n**/* -text -diff\n')
assert 'All tests passed!' in (raw/'desktop-tests-final.txt').read_text();assert '+209 ~2:' in (raw/'desktop-tests-final.txt').read_text();assert 'No issues found!' in (raw/'desktop-analysis-accepted.txt').read_text()
v={'date':'2026-10-22','sourceBase':'63e1ce9d612e5afac84adb838b54c2fff67db838','baselineQueryTestsFailed':2,'initialRelatedPassed':16,'finalFullDesktopPassed':209,'finalFullDesktopConditionalSkipped':2,'strictAnalysisExit':0,'finalReleaseBuildAndSignatureExit':0,'ordinaryInstallChanged':False,'latestF93CandidateIncludesThisFix':False,'obscuredAccessibilityPrivacyAccepted':False,'newKeychainCalls':0,'newOSPermissionRequests':0,'windowsNativeOrCI':False,'issue48Criteria':[True,True,True,False,False,False],**cleanup};v['files']=[{'path':str(p.relative_to(ev)),'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(raw.rglob('*')) if p.is_file()];(ev/'verification.json').write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n');print(json.dumps({'files':len(v['files']),**cleanup},ensure_ascii=False,indent=2))
