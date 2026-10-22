from pathlib import Path
import hashlib,json,os,shutil,stat,subprocess
r=Path.cwd();b=r/'build/macos-adaptation/issue48-ime-chinese-reopen-20261022';ev=r/'docs/development/evidence/macos-native-ime';raw=ev/'raw/chinese-reopen';raw.mkdir(parents=True,exist_ok=True)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();d=json.loads((b/'result.json').read_text())
assert d['complete'] and d['expectedSavedDescription']=='你好测试\n你好' and d['ownedPrivateTargetsAndGeneratedAppRemoved'] and d['unregisterExitCode']==0 and not d.get('failure') and not d.get('forcedFailureCleanup')
assert len(d['commands'])==8 and all(x['exitCode']==0 for x in d['commands'])
assert len(d['processExits'])==2 and d['processExits'][0]['pid']!=d['processExits'][1]['pid'] and all(x['exitCode']==0 for x in d['processExits'])
assert len(d['cases'])==2 and d['cases'][0]['actualUiSaved'] and d['cases'][1]['savedDescriptionPreserved']
for x in d['cases']:
 assert x['complete'] and x['expectedSavedDescription']=='你好测试\n你好' and x['libraryCloses']==1 and x['flutterErrors']==0 and x['portClosedAfterExit'] and not x['systemKeychainUsed'] and x['otherFieldsAndAttachmentPreserved']
 assert x['inputSourceAtStart']==x['inputSourceAtEnd']=='com.apple.inputmethod.SCIM.ITABC'
for n,h in d['inputSourceHashes'].items():
 assert sha(r/n)==h,n
 if n not in d['copyModifications']:assert (b/'source'/n).read_bytes()==(r/n).read_bytes(),n
for n,h in d['copyModifications'].items():assert sha(b/'source'/n)==h
for n in ['chinese-before-app-reopen.json','chinese-after-app-reopen.json']:
 x=json.loads((b/n).read_text());assert x['actualDescription']=='你好测试\n你好' and x['SQLITE_OPEN_READONLY'] and x['databaseWalShmBytesUnchanged'] and x['integrity']=='ok'
for p in b.glob('*.json'):
 assert p.name!='controller.json';shutil.copy2(p,raw/p.name)
shutil.copytree(b/'logs',raw/'logs',dirs_exist_ok=True)
for n in ['scripts/qa/macos-editor-focus-ui.py','apps/desktop/integration_test/macos_editor_focus_manual.dart']:
 shutil.copy2(r/n,raw/Path(n).name)
for n in d['copyModifications']:
 p=raw/'qa-copy'/n;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(b/'source'/n,p)
shutil.copy2(b/'read-chinese-save.py',raw/'read-chinese-save.py');shutil.copy2(__file__,raw/'archive-cleanup.py')
notes={'scope':'Second run fixes only prior harness expected-text limit, using immutable QA source701de67','actualCUAKeys':'Command+A/Backspace; n i h a o Space; c e s h i Space; Return; n i h a o Space; actual Save','expectedSavedDescription':'你好测试\n你好','firstAppPid':d['processExits'][0]['pid'],'independentReopenAppPid':d['processExits'][1]['pid'],'actualReopenCUAView':'Information library list and detail both show exact two-line Chinese, BaselineValue and seven-byte attachment v1','chineseAppProcessReopenProven':True,'readOnlySQLCipherCheckedBeforeAndAfterAppReopen':True,'ASCIIReplacementUsedThisRun':False,'controllerOrRepositoryTextInjection':False,'CuaSnapshots':'Emitted inline; no archived PNG claimed','newOSPermissionRequests':0,'inputSourceChanged':False,'finalOrdinaryZIPEntryProven':False}
(raw/'cua-observations.json').write_text(json.dumps(notes,ensure_ascii=False,indent=2)+'\n')
assert str(b/'source') not in subprocess.check_output(['ps','-axo','pid,comm'],text=True)
p=b/'source';assert p.is_dir() and not p.is_symlink();kb=int(subprocess.check_output(['du','-sk',str(p)],text=True).split()[0]);shutil.rmtree(p)
install=r/'local/中文 Mac 预览/AgentInfoManage';m=json.loads((install/'manifest.json').read_text())
for row in m['files']:
 p=install/row['path']
 assert (p.is_symlink() and os.readlink(p)==row['link']) if 'link' in row else (p.is_file() and not p.is_symlink() and p.stat().st_size==row['bytes'] and stat.S_IMODE(p.stat().st_mode)==row['mode'] and sha(p)==row['sha256']),row['path']
s=subprocess.run(['codesign','--verify','--deep','--strict',str(install/'app/info_desktop.app')],capture_output=True,text=True);assert s.returncode==0;os.kill(53592,0)
apps=[];symbols=[]
for root in [r/'build/macos-adaptation',r/'local',r/'apps/desktop/build']:
 for path,dirs,files in os.walk(root,followlinks=False):
  for n in dirs[:]:
   p=Path(path)/n
   if p.is_symlink():dirs.remove(n)
   elif n.endswith(('.app','.dSYM')):(apps if n.endswith('.app') else symbols).append(str(p.relative_to(r)));dirs.remove(n)
assert apps==['local/中文 Mac 预览/AgentInfoManage/app/info_desktop.app'] and not symbols
(raw/'cleanup.json').write_text(json.dumps({'sourceInputsVerified':len(d['inputSourceHashes']),'driverOwnedLibraryAppAndCachesRemoved':True,'additionalSourceRemoved':True,'releasedAllocatedKiB':kb,'stablePayloadItemsVerified':len(m['files']),'stableStrictSignatureExit':0,'stablePid53592Alive':True,'remainingApps':apps,'remainingGeneratedDsyms':symbols,'SDKCacheZIPsPrivateBackupsPreserved':True},ensure_ascii=False,indent=2)+'\n')
v=json.loads((ev/'verification.json').read_text());v['firstRoundFrozenQASource']=v.pop('frozenQASource');v['chineseReopenFrozenQASource']=d['sourceCommit'];v['sourceInputsPerRound']=[v.pop('sourceInputsVerified'),len(d['inputSourceHashes'])];v['strictPreparationPhasesPerRound']=[8,8];v.pop('strictPreparationPhases');v['chineseAppProcessReopenProven']=True;v['actualCUACommandQNormalExits']=4;v['portsClosedAfterAllFourExits']=True;v.pop('portsClosedAfterBothExits');v['raw']=[{'path':p.relative_to(ev).as_posix(),'bytes':p.stat().st_size,'sha256':sha(p)} for p in sorted((ev/'raw').rglob('*')) if p.is_file()];(ev/'verification.json').write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n');print(json.dumps({'rawFiles':len(v['raw']),'sourceInputsPerRound':v['sourceInputsPerRound'],'ChineseReopenProven':True,'additionalSourceCleanedMiB':round(kb/1024,1),'apps':apps,'generatedDsyms':symbols},ensure_ascii=False))
