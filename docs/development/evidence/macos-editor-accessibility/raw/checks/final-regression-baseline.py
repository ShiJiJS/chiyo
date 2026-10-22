from pathlib import Path
import hashlib,json,shutil,subprocess
r=Path.cwd();b=r/'build/macos-adaptation/issue48-voiceover-20261022';source=b/'baseline-unit-source';source.mkdir(exist_ok=False);archive=b/'baseline-unit.tar';test='apps/desktop/test/information_editor_semantics_test.dart';commit='fffd7ac6c738f11f74a80fd9cc11070798be9a97'
try:
 with archive.open('wb') as out:subprocess.run(['git','archive',commit,'apps/desktop','packages','scripts','integrations','third_party'],stdout=out,check=True)
 subprocess.run(['tar','-xf',str(archive),'-C',str(source)],check=True);archive.unlink()
 for n in ['.tools','.downloads']:(source/n).symlink_to(r/n,target_is_directory=True)
 (source/'.cache').mkdir();(source/'.cache/pub').symlink_to(r/'.cache/pub',target_is_directory=True);shutil.copy2(r/test,source/test)
 launcher=str(source/'scripts/dev-macos.sh');desktop=source/'apps/desktop'
 with (b/'final-regression-red-pub.txt').open('wb') as out:pub=subprocess.run([launcher,'flutter','pub','get','--enforce-lockfile'],cwd=desktop,stdout=out,stderr=subprocess.STDOUT,timeout=300)
 assert pub.returncode==0
 with (b/'final-regression-red.txt').open('wb') as out:run=subprocess.run([launcher,'flutter','test','--no-pub','test/information_editor_semantics_test.dart','--reporter','expanded'],cwd=desktop,stdout=out,stderr=subprocess.STDOUT,timeout=300)
 text=(b/'final-regression-red.txt').read_text();assert run.returncode==1 and text.count('Test failed. See exception logs above.')==4
 assert "Expected: '信息名称'" in text and "Actual: ''" in text and "does not contain '所在目录'" in text
 facts={'baselineProductSource':commit,'exactFinalTestSha256':hashlib.sha256((r/test).read_bytes()).hexdigest(),'pubExitCode':pub.returncode,'testExitCode':run.returncode,'failedCases':4,'failureScope':'Mac+Windows widget variants: editable purpose empty and directory purpose absent','realWindowsRunnerUsed':False}
finally:
 if source.exists():
  assert not source.is_symlink();shutil.rmtree(source)
 archive.unlink(missing_ok=True)
 facts['ownedSourceRemoved']=True
 (b/'final-regression-red.json').write_text(json.dumps(facts,indent=2)+'\n')
print(json.dumps(facts))
