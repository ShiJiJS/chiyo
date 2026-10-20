from pathlib import Path
import os,sys,json,subprocess,ast
root=Path.cwd();out=root/'build/qa-issue39/qa-lint-01';out.mkdir(parents=True,exist_ok=False)
env=os.environ.copy();env.update(PUB_HOSTED_URL='https://pub.flutter-io.cn',FLUTTER_STORAGE_BASE_URL='https://storage.flutter-io.cn')
locks={root/p/'pubspec.lock':(root/p/'pubspec.lock').read_bytes() for p in ['packages/info_core','packages/info_storage','packages/info_cli','apps/desktop']};norm=lambda b:b.replace(b'https://pub.flutter-io.cn',b'https://pub.dev').replace(b'\r\n',b'\n');phases=[]
def run(name,cmd,cwd):
 with (out/(name+'.txt')).open('wb') as log:p=subprocess.run(cmd,cwd=cwd,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=300)
 phases.append(dict(phase=name,exitCode=p.returncode));print(json.dumps(phases[-1]),flush=True)
 if p.returncode:print((out/(name+'.txt')).read_text(encoding='utf-8',errors='replace')[-9000:]);raise RuntimeError(name)
try:
 for p,b in locks.items():p.write_bytes(b.replace(b'https://pub.dev',b'https://pub.flutter-io.cn'))
 dart='C:/Users/Todoki/.local/share/flutter/bin/dart.bat'
 ast.parse((root/'scripts/test-windows-app-control.py').read_text(encoding='utf-8'));phases.append(dict(phase='python-syntax',exitCode=0))
 run('fixture-format',[dart,'format','test/support/packaged_control_fixture.dart'],root/'packages/info_storage')
 run('storage-pub',[dart,'pub','get','--enforce-lockfile','--offline'],root/'packages/info_storage')
 run('storage-analyze',[dart,'analyze','--fatal-infos'],root/'packages/info_storage')
 run('transport-format',[dart,'format','test/transport_test.dart'],root/'packages/info_core')
 run('core-pub',[dart,'pub','get','--enforce-lockfile','--offline'],root/'packages/info_core')
 run('core-analyze',[dart,'analyze','--fatal-infos'],root/'packages/info_core')
 run('transport',[dart,'test','test/transport_test.dart','-r','expanded'],root/'packages/info_core')
 app=root/'build/windows-preview-0.4.0-11-887f1c2/AgentInfoManage/cli/info.exe'
 p=subprocess.run([str(app)],input='{"command":"app","action":"quit"}\n',capture_output=True,text=True,encoding='utf-8',timeout=10,creationflags=subprocess.CREATE_NO_WINDOW)
 (out/'json-lines.txt').write_text(p.stdout,encoding='utf-8');assert p.returncode==0 and json.loads(p.stdout)=={'status':'invalid_request'}
 phases.append(dict(phase='json-lines-cannot-quit',exitCode=0))
finally:
 bad=[]
 for p,b in locks.items():
  if norm(p.read_bytes())!=norm(b):bad.append(str(p))
  else:p.write_bytes(b)
 (out/'result.json').write_text(json.dumps(dict(phases=phases,unexpectedLocks=bad),indent=2)+'\n',encoding='utf-8');assert not bad,bad
