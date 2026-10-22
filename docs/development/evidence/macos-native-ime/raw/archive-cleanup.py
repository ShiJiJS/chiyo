from pathlib import Path
import hashlib,json,os,shutil,stat,subprocess
r=Path.cwd();b=r/'build/macos-adaptation/issue48-ime-current-20261022';ev=r/'docs/development/evidence/macos-native-ime';raw=ev/'raw';raw.mkdir(parents=True,exist_ok=True)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();d=json.loads((b/'result.json').read_text())
assert d['complete'] and d['ownedPrivateTargetsAndGeneratedAppRemoved'] and d['unregisterExitCode']==0 and not d.get('failure') and not d.get('forcedFailureCleanup')
assert len(d['commands'])==8 and all(x['exitCode']==0 for x in d['commands'])
assert len(d['cases'])==2 and len(d['processExits'])==2 and all(x['exitCode']==0 for x in d['processExits'])
assert all(x['complete'] and x['libraryCloses']==1 and x['flutterErrors']==0 and x['portClosedAfterExit'] and not x['systemKeychainUsed'] and x['otherFieldsAndAttachmentPreserved'] for x in d['cases'])
assert all(x['inputSourceAtStart']==x['inputSourceAtEnd']=='com.apple.inputmethod.SCIM.ITABC' for x in d['cases'])
for n,h in d['inputSourceHashes'].items():
 assert sha(r/n)==h,n
 if n not in d['copyModifications']:assert (b/'source'/n).read_bytes()==(r/n).read_bytes(),n
for n,h in d['copyModifications'].items():assert sha(b/'source'/n)==h
get=lambda n:json.loads((b/n).read_text())
assert get('nihao-composing.json')['editingValue']=={'text':'ni hao','selection':[6,6],'composing':[0,6]}
assert get('nihao-committed.json')['editingValue']=={'text':'你好','selection':[2,2],'composing':[-1,-1]}
assert get('zhongwen-composing.json')['editingValue']['composing']==[2,11]
x=get('escape-cancelled-composition.json');assert x['editingValue']['text']=='你好' and x['editingValue']['composing']==[2,2] and x['editor'] and not x['confirmation'] and x['persistedDescription']=='BaselineDescription'
assert get('chinese-multiline-before-save.json')['editingValue']['text']=='你好测试\n你好'
assert get('chinese-unsaved-confirm.json')['confirmation'] and get('chinese-unsaved-confirm.json')['persistedDescription']=='BaselineDescription'
assert get('chinese-cancel-preserved.json')['editor']['description']=='你好测试\n你好'
assert get('chinese-actual-save.json')['persistedDescription']=='你好测试\n你好'
assert get('chinese-native-panel-cancel.json')['focusKeys']==['item-description']
assert get('panel-cancel-resumed-composition.json')['editingValue']['composing']==[4,13]
for n in ['chinese-sqlcipher-before-discard.json','chinese-sqlcipher-after-discard.json']:
 x=get(n);assert x['actualDescription']=='你好测试\n你好' and x['integrity']=='ok' and x['schema']==22 and x['SQLITE_OPEN_READONLY'] and x['databaseWalShmBytesUnchanged']
assert get('search-nihao-composing.json')['editingValue']['composing']==[0,6]
assert get('search-nihao-committed.json')['editingValue']['text']=='你好'
for p in b.glob('*.json'):
 if p.name in ['controller.json','issue48-before.json']:continue
 shutil.copy2(p,raw/p.name)
shutil.copytree(b/'logs',raw/'logs',dirs_exist_ok=True)
for n in ['read-input-source.swift','input-source-after-ime.txt','read-chinese-save.py']:
 shutil.copy2(b/n,raw/n)
for n in ['scripts/qa/macos-editor-focus-ui.py','apps/desktop/integration_test/macos_editor_focus_manual.dart']:
 shutil.copy2(r/n,raw/Path(n).name)
for n in d['copyModifications']:
 p=raw/'qa-copy'/n;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(b/'source'/n,p)
shutil.copy2(__file__,raw/'archive-cleanup.py')
notes={'scope':'CUA actions in actual ordinary-binding sandbox QA app; passive controller/focus/composition observer','realSCIMInputSource':'com.apple.inputmethod.SCIM.ITABC','inputSourceChanged':False,'OSSettingsChanged':False,'actualPinyinKeySequence':'n,i,h,a,o; Space commits 你好; no typeText/paste for IME evidence','compositionEscape':'Cancels pending zhong wen; committed 你好 remains, collapsed composing[2,2], editor stays open, no discard prompt','multiLineSaved':'你好测试\n你好','cancelDiscardPrompt':'Escape opens prompt only after composition ends; Escape retains Chinese draft','search':'ni hao composing => visible0 results; Space commits你好 => visible1 result; clear restores unfiltered list','nativePanel':'Actual file picker opened from visible button after native scrollbar drag; Escape cancels; focusKeys item-description restored; next actual key sequence composes [4,13] without clicking text again','discard':'New 中文 draft explicitly discarded; original saved Chinese retained and read-only SQLCipher verified again','checkpoint':'Existing harness then saves ASCII MacFocusSaved by paste, not counted as IME; independent app reopen verifies this ASCII checkpoint and original field/7-byte attachment','chineseAppProcessReopenProven':False,'CUAScreenshots':'Shown inline only; no archived PNG claimed','physicalHumanKeyboardOrVoiceOverProven':False,'finalOrdinaryZIPEntryProven':False,'newOSPermissionRequests':0,'stableAppReplaced':False}
(raw/'cua-observations.json').write_text(json.dumps(notes,ensure_ascii=False,indent=2)+'\n')
processes=subprocess.check_output(['ps','-axo','pid,comm'],text=True);assert str(b/'source') not in processes
removed=[]
for p in [b/'source',b/'read-input-source']:
 if not p.exists():continue
 assert not p.is_symlink();kb=int(subprocess.check_output(['du','-sk',str(p)],text=True).split()[0]);removed.append({'path':str(p.relative_to(r)),'allocatedKiB':kb})
 if p.is_dir():shutil.rmtree(p)
 else:p.unlink()
install=r/'local/中文 Mac 预览/AgentInfoManage';m=json.loads((install/'manifest.json').read_text());bad=[]
for row in m['files']:
 p=install/row['path'];ok=(p.is_symlink() and os.readlink(p)==row['link']) if 'link' in row else (p.is_file() and not p.is_symlink() and p.stat().st_size==row['bytes'] and stat.S_IMODE(p.stat().st_mode)==row['mode'] and sha(p)==row['sha256'])
 if not ok:bad.append(row['path'])
assert not bad
s=subprocess.run(['codesign','--verify','--deep','--strict',str(install/'app/info_desktop.app')],capture_output=True,text=True);assert s.returncode==0;os.kill(53592,0)
apps=[];symbols=[]
for root in [r/'build/macos-adaptation',r/'local',r/'apps/desktop/build']:
 for path,dirs,files in os.walk(root,followlinks=False):
  for name in dirs[:]:
   p=Path(path)/name
   if p.is_symlink():dirs.remove(name)
   elif name.endswith(('.app','.dSYM')):(apps if name.endswith('.app') else symbols).append(str(p.relative_to(r)));dirs.remove(name)
assert apps==['local/中文 Mac 预览/AgentInfoManage/app/info_desktop.app'] and not symbols
clean={'sourceInputsVerified':len(d['inputSourceHashes']),'ownedPrivateTargetsAndAppAlreadyRemovedByDriver':True,'additionalRemoved':removed,'releasedAllocatedKiB':sum(x['allocatedKiB'] for x in removed),'stablePayloadItems':len(m['files']),'stableMismatches':bad,'stableStrictSignatureExit':0,'stablePid53592Alive':True,'remainingApps':apps,'remainingGeneratedDsyms':symbols,'SDKCacheZIPsPrivateBackupsPreserved':True}
(raw/'cleanup.json').write_text(json.dumps(clean,ensure_ascii=False,indent=2)+'\n')
(ev/'.gitattributes').write_text('* -text -diff\n**/* -text -diff\n')
v={'date':'2026-10-22','frozenQASource':d['sourceCommit'],'productionCandidateSource':'5a509968400b2d140a69a02f89935c5db4e935ee','productChanged':False,'sourceInputsVerified':len(d['inputSourceHashes']),'strictPreparationPhases':8,'ordinaryWidgetsBinding':True,'diagnoseKeysMessengerUsed':False,'realSCIMPinyinCompositionAndCommit':True,'compositionEscapeKeepsEditorAndCommittedText':True,'ChineseMultilineActualSaveAndIndependentSQLCipherReadOnlyCheck':True,'nativePanelCancelAndImmediateIMEFocusResume':True,'realChineseSearch':True,'chineseAppProcessReopenProven':False,'separateASCIIHarnessCheckpointAppReopen':True,'actualCUACommandQNormalExits':2,'libraryClosesEach':1,'portsClosedAfterBothExits':True,'systemKeychainUsed':False,'newOSPermissionRequests':0,'inputSourceChanged':False,'physicalHumanKeyboardOrVoiceOverProven':False,'finalOrdinaryZIPEntryProven':False,'issue48Criteria':[True,True,True,False,False,False],'raw':[{'path':p.relative_to(ev).as_posix(),'bytes':p.stat().st_size,'sha256':sha(p)} for p in sorted(raw.rglob('*')) if p.is_file()]}
(ev/'verification.json').write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n');print(json.dumps({'rawFiles':len(v['raw']),'sourceInputs':v['sourceInputsVerified'],'extraCleanedMiB':round(clean['releasedAllocatedKiB']/1024,1),'apps':apps,'generatedDsyms':symbols},ensure_ascii=False))
