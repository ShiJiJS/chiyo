from pathlib import Path
import subprocess,json,hashlib,shutil,os,stat
root=Path.cwd();out=Path(__file__).resolve().parent;ev=root/'docs/development/evidence/macos-secure-field-diagnosis';raw=ev/'raw';raw.mkdir(parents=True,exist_ok=True)
names=['prepare.py','prepare-native-embedded.py','prepare-sheet.py','build.py','run.py','prepared.json','sdk-source-context.json','native-build.json','baseline-build-run.txt','baseline-build-run-2.txt','baseline-analysis-first.txt','current-build-run.txt','embedded-build-run.txt','embedded-semantics-build-run.txt','sheet-build-run.txt','baseline-MainFlutterWindow.swift','baseline-secure_ax_probe.dart','current-MainFlutterWindow.swift','current-secure_ax_probe.dart','embedded-MainFlutterWindow.swift','embedded-unforced-secure_ax_probe.dart','embedded-semantics-secure_ax_probe.dart']
for phase in ['native','baseline','current','embedded-unforced','embedded','sheet']:
 for suffix in ['runtime.txt','process.json','signature.txt','exit.json']:
  names.append(phase+'-'+suffix)
for phase in ['baseline','current','embedded-unforced','embedded-semantics']:
 for suffix in ['build-stages.json','build-probe.txt','analyze-probe.txt','format-probe.txt']:
  names.append(phase+'-'+suffix)
for n in ['build-stages.json','build-probe.txt','analyze-probe.txt','format-probe.txt']:
 shutil.copy2(out/n,raw/('sheet-'+n))
for n in names:shutil.copy2(out/n,raw/n)
for i in range(3):shutil.copy2(out/f'native-build-{i}.txt',raw/f'native-build-{i}.txt')
shutil.copy2(out/'native/Control.swift',raw/'native-Control.swift');shutil.copy2(out/'native/entitlements.plist',raw/'native-entitlements.plist')
for name in ['apps/desktop/lib/secure_ax_probe.dart','apps/desktop/macos/Runner/MainFlutterWindow.swift']:
 p=raw/'sheet-source'/name;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(out/'source'/name,p)
for name in ['apps/desktop/lib/mac_text_editing.dart','apps/desktop/macos/Runner/NativeTextEditingMenu.swift','apps/desktop/lib/window_frame.dart']:
 p=raw/'production-source'/name;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(root/name,p);assert (out/'source'/name).read_bytes()==(root/name).read_bytes()
assert (out/'current-MainFlutterWindow.swift').read_bytes()==(root/'apps/desktop/macos/Runner/MainFlutterWindow.swift').read_bytes()
a=(out/'baseline-secure_ax_probe.dart').read_text().replace('const bridgeEnabled = false;','const bridgeEnabled = true;');assert a==(out/'current-secure_ax_probe.dart').read_text()
(raw/'source-comparison.json').write_text(json.dumps({'baselineAndCurrentDartDifferOnlyBridgeFlag':True,'currentNativeWindowExactProduction':True,'allThreeProductBridgeSourcesExact':True,'productionFilesUnchanged':True},indent=2)+'\n')
obs={'kind':'Actual CUA AX/screenshots transcribed, not separately saved screenshots','nativeControl':{'pid':96247,'nativeSecureRoleAndMaskedValueAfterFocusSelectMenuPanel':True,'copyCutDisabled':True,'panelCancelled':True,'exit':0},'noBridgeFlutter':{'pid':97311,'bothNativeAndDartMenuBridgeAbsent':True,'alwaysObscuredAfterTypedZInitiallyMasked':True,'nativeCopyCutEnabled':True,'afterToggleAndPanelAXContainedKnownTogglePlaintextInTwoFields':True,'bothVisualSecretFieldsStillDots':True,'exit':0},'currentBridgeFlutter':{'pid':97941,'sourcesBase':'aa9fdd3','copyCutDisabledAfterQuery':True,'alwaysObscuredAfterSelectAllMenuCloseAXContainedActualKnownSecretVariant':True,'afterToggleAndPanelAXContainedKnownTogglePlaintextInTwoFields':True,'exit':0},'embeddedWithoutForcedSemantics':{'pid':98560,'onlyNativeSecureFieldInAXTree':True,'AXElementClickReachedUnderlyingFlutterField':True,'coordinateClickNativeTypingReachedDartLength20':True,'programmaticReplacementReachedDartExact':True,'nativeFieldRemainedSecureAfterPanelCancel':True,'integrationAccepted':False,'exit':0},'embeddedWithDartEnsureSemantics':{'pid':99195,'AXTreeUpdateFailedPendingNode':15,'otherFlutterControlsNotExposed':True,'TabReturnedFocusToContainerWithoutCompleteTree':True,'ownNativeControlAXValueMasked':True,'integrationAccepted':False,'exit':0},'nativeSheet':{'pid':99966,'mainTreeCompleteAndNoFlutterSecretEditor':True,'nativeSecureRoleAndMaskedValueWhileTyping':True,'typedReplacementThenCancelRetainedOriginal':True,'reopenShowedOriginalMaskedLength':16,'acceptTypedReplacementReachedDartExact':True,'updatedLength':23,'copyCutDisabledInSheet':True,'EscapeCancelledAndRetainedAcceptedValue':True,'ordinaryFieldStillEditableAndTreeComplete':True,'prototypePassed':True,'productionIntegrated':False,'exit':0},'limits':['Synthetic fixtures only; no real secrets or Keychain','No VoiceOver speech session performed','AX observation and own-control NSAccessibility property inspection are distinct scopes','No full production form integration or same-package ordinary GUI acceptance','No Windows native verification'],'newOSPermissionRequests':0,'keychainCalls':0,'clipboardWritesByFixtures':0}
(raw/'actual-ui-observations.json').write_text(json.dumps(obs,ensure_ascii=False,indent=2)+'\n')
for phase in ['native','baseline','current','embedded-unforced','embedded','sheet']:
 assert json.loads((out/(phase+'-exit.json')).read_text())['exitCode']==0
for phase in ['baseline','current','embedded-unforced','embedded-semantics']:
 stages=json.loads((out/(phase+'-build-stages.json')).read_text());assert len(stages)==7 and all(x['exitCode']==0 for x in stages)
assert all(x['exitCode']==0 for x in json.loads((out/'build-stages.json').read_text()))
assert 'updatedExact=true' in (out/'sheet-runtime.txt').read_text();assert 'Nodes left pending by the update: 15' in (out/'embedded-runtime.txt').read_text()
ps=subprocess.check_output(['ps','-axo','pid,comm'],text=True);assert not any(x.rstrip().endswith(('/MacAXNativeControl','/MacAXFlutterControl')) for x in ps.splitlines())
reg='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister';unregs=[]
for app in [out/'native/MacAXNativeControl.app',out/'source/apps/desktop/build/macos/Build/Products/Release/MacAXFlutterControl.app']:
 r=subprocess.run([reg,'-u',str(app)],capture_output=True,text=True);assert r.returncode==0;unregs.append({'path':str(app.relative_to(root)),'exit':r.returncode})
removed=[]
for d in [out/'native',out/'source']:
 kb=int(subprocess.check_output(['du','-sk',str(d)],text=True).split()[0]);shutil.rmtree(d);removed.append({'path':str(d.relative_to(root)),'allocatedKiB':kb})
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
clean={'unregistered':unregs,'removed':removed,'releasedAllocatedKiB':sum(x['allocatedKiB'] for x in removed),'stableItemsVerified':len(m['files']),'stableMismatches':bad,'stableSignatureExit':r.returncode,'stablePid53592Alive':True,'remainingApps':apps,'remainingGeneratedDsyms':dsyms,'sdksZIPsBackupsRecoveryKeysPreserved':True};(raw/'cleanup.json').write_text(json.dumps(clean,ensure_ascii=False,indent=2)+'\n')
shutil.copy2(__file__,raw/'archive-cleanup.py');(ev/'.gitattributes').write_text('* -text -diff\n**/* -text -diff\n')
v={'date':'2026-10-22','sourceBase':'aa9fdd35c848aeafd6e74bf2b22fd0ea7b85bd7a','productionCodeChanged':False,'normalDesktopTestsRerun':False,'flutterFixtureReleaseBuildsPassed':5,'nativeControlBuildPassed':True,'fixtureProcessesExitedZero':6,'secretAccessibilityBugReproduced':True,'embeddedNativeWorkaroundAccepted':False,'nativeSheetPrototypePassed':True,'productionSecureEntryFixed':False,'keychainCalls':0,'newOSPermissionRequests':0,'upstreamRelatedIssue':'https://github.com/flutter/flutter/issues/170721','upstreamIssueObservedOpen':True,'issue48Criteria':[True,True,True,False,False,False],**clean};v['files']=[{'path':str(p.relative_to(ev)),'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(raw.rglob('*')) if p.is_file()];(ev/'verification.json').write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n');print(json.dumps({'files':len(v['files']),**clean},ensure_ascii=False,indent=2))
