from pathlib import Path
import hashlib,json,os,plistlib,shutil,stat,subprocess
r=Path.cwd();b=r/'build/macos-adaptation/issue44-library-current-tools-20261022';ev=r/'docs/development/evidence/macos-library-tools-current';raw=ev/'raw';raw.mkdir(parents=True,exist_ok=True)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
d=json.loads((b/'result.json').read_text());m=json.loads((r/'build/macos-adaptation/issue50-package-16/preserved-manifest.json').read_text())
assert d['complete'] and d['ownedFixturesRemoved'] and d['unregisterExitCode']==0 and not d.get('failure') and not d.get('forcedFailureCleanup')
assert len(d['commands'])==8 and all(x['exitCode']==0 for x in d['commands'])
c=d['cases'];assert len(c)==1 and c[0]['exitCode']==0 and c[0]['nativeTerminationRequested'] and c[0]['libraryCloses']==1 and c[0]['flutterErrors']==0
assert [x['exitCode'] for x in c[0]['executions']]==[0,0,0,254,1]
assert all(x['duplicateStable'] and x['deadlineUnchanged'] and x['outputSecretsAbsent'] for x in c[0]['executions'])
for name,h in d['inputSourceHashes'].items():
 assert sha(r/name)==h,name
 if name not in d['copyModifications']:assert (b/'source'/name).read_bytes()==(r/name).read_bytes(),name
for name,h in d['copyModifications'].items():assert sha(b/'source'/name)==h
mt=next(x for x in m['files'] if x['path']=='app/info_desktop.app/Contents/Resources/ThirdParty/manifest.json')
assert mt['sha256']==d['productionBundledTools']['manifestSha256']
ent=(b/'logs/entitlements.txt').read_bytes();ent=plistlib.loads(ent[ent.index(b'<?xml'):]);assert ent==m['appEntitlements'] and ent['com.apple.security.app-sandbox']
recv=json.loads((b/'receiver/receiver-result.json').read_text());assert recv['valid']==3 and recv['invalid']==1
for n in ['result.json','bundled.json','last-bundled-result.json']:
 shutil.copy2(b/n,raw/n)
shutil.copytree(b/'logs',raw/'logs',dirs_exist_ok=True)
shutil.copy2(b/'receiver/receiver-result.json',raw/'receiver-result.json')
shutil.copy2(r/'build/macos-adaptation/issue19-remaining-gates-20261022/current-tools-supervisor.txt',raw/'supervisor.txt')
for name in ['scripts/qa/macos-tools-ui.py','scripts/qa/macos-aws-receiver.py','apps/desktop/integration_test/macos_tools_manual.dart']:
 shutil.copy2(r/name,raw/Path(name).name)
shutil.copy2(__file__,raw/'archive-cleanup.py')
notes={'actualCUAApprovals':3,'actualCUAHistoryGrantsViewed':3,'goodAWSHistoryOperationCount':3,'goodAWSHistoryOperations':['aws-identity','aws-write','aws-read'],'goodAWSHistoryDeadline':'12:54:59','goodAWSHistoryLatestCleanup':'已清理','ghHistoryOperation':'gh-invalid','ghHistoryExitCode':1,'actualQuit':'CUA Command+Q; app exit0','windowContentLogicalPixels':[800,600],'nativeScrollbarDragUsed':True,'approvalBodyAXCoverage':'limited; screenshot coordinates and actual scrollbar used; confirmation dialogs exposed semantics','screenshots':'Emitted in conversation only; no archived PNG claimed','processReopenTestedThisRun':False,'finalOrdinaryZIPGUIProven':False,'keychainUsed':False,'newSystemPermissionPrompts':0,'physicalIMEOrVoiceOverProven':False}
(raw/'cua-observations.json').write_text(json.dumps(notes,ensure_ascii=False,indent=2)+'\n')
processes=subprocess.check_output(['ps','-axo','pid,comm'],text=True);assert str(b/'source') not in processes
removed=[]
for p in [b/'source',b/'receiver/fixture.json']:
 if not p.exists():continue
 assert not p.is_symlink();kb=int(subprocess.check_output(['du','-sk',str(p)],text=True).split()[0]);removed.append({'path':str(p.relative_to(r)),'allocatedKiB':kb})
 if p.is_dir():shutil.rmtree(p)
 else:p.unlink()
install=r/'local/中文 Mac 预览/AgentInfoManage';stable=json.loads((install/'manifest.json').read_text());bad=[]
for row in stable['files']:
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
clean={'sourceInputsVerified':len(d['inputSourceHashes']),'candidateToolManifestIdentical':True,'candidateEntitlementsIdentical':True,'ownedFixturesAndAppAlreadyRemovedByDriver':True,'additionalRemoved':removed,'releasedAllocatedKiB':sum(x['allocatedKiB'] for x in removed),'stablePayloadItems':len(stable['files']),'stableMismatches':bad,'stableDeepStrictSignatureExit':0,'stablePid53592Alive':True,'remainingApps':apps,'remainingGeneratedDsyms':symbols,'sdkCachesZIPsPrivateBackupsPreserved':True}
(raw/'cleanup.json').write_text(json.dumps(clean,ensure_ascii=False,indent=2)+'\n')
(ev/'.gitattributes').write_text('* -text -diff\n**/* -text -diff\n')
v={'date':'2026-10-22','frozenQASource':d['sourceCommit'],'productionCandidateSource':m['sourceCommit'],'productionChanged':False,'sourceInputsVerified':len(d['inputSourceHashes']),'strictPreparationPhases':8,'actualCUAApprovals':3,'independentReceiverValid':3,'independentReceiverInvalid':1,'operationCount':5,'duplicateExecutionStableCount':5,'deadlineUnchangedCount':5,'awsMaterialCleanupCompleteCount':4,'ghRealHTTP401Asserted':True,'ghAccountSuccessClaimed':False,'actualCUACommandQNormalExit':True,'libraryCloses':1,'keychainUsed':False,'newOSPermissionPrompts':0,'processReopenTestedThisRun':False,'finalOrdinaryZIPGUIProven':False,'physicalIMEOrVoiceOverProven':False,'issue44Criteria':[True,False,False,True,True,False],'issue48Criteria':[True,True,True,False,False,False],'issue50Criteria':[True,True,False,False,False,False],'raw':[{'path':p.relative_to(ev).as_posix(),'bytes':p.stat().st_size,'sha256':sha(p)} for p in sorted(raw.rglob('*')) if p.is_file()]}
(ev/'verification.json').write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'sourceInputs':len(d['inputSourceHashes']),'candidateManifestAndEntitlementsIdentical':True,'rawFiles':len(v['raw']),'extraCleanedMiB':round(clean['releasedAllocatedKiB']/1024,1),'remainingApps':apps,'generatedDsyms':symbols},ensure_ascii=False))
