from pathlib import Path
import os,sys,json,subprocess
root=Path.cwd();out=root/'build/qa-issue39'/sys.argv[1];out.mkdir(parents=True,exist_ok=False)
env=os.environ.copy();env.update(PUB_HOSTED_URL='https://pub.flutter-io.cn',FLUTTER_STORAGE_BASE_URL='https://storage.flutter-io.cn')
locks={root/p/'pubspec.lock':(root/p/'pubspec.lock').read_bytes() for p in ['packages/info_core','packages/info_storage','packages/info_cli','apps/desktop']}
norm=lambda b:b.replace(b'https://pub.flutter-io.cn',b'https://pub.dev').replace(b'\r\n',b'\n')
dart='C:/Users/Todoki/.local/share/flutter/bin/dart.bat';flutter='C:/Users/Todoki/.local/share/flutter/bin/flutter.bat'
phases=[]
def run(name,cmd,folder):
 with (out/(name+'.txt')).open('wb') as log:r=subprocess.run(cmd,cwd=root/folder,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=600)
 phases.append(dict(phase=name,exitCode=r.returncode));print(json.dumps(phases[-1]),flush=True)
 if r.returncode:
  print((out/(name+'.txt')).read_text(encoding='utf-8',errors='replace')[-9000:],flush=True);raise RuntimeError(name)
try:
 for p,b in locks.items():p.write_bytes(b.replace(b'https://pub.dev',b'https://pub.flutter-io.cn'))
 run('core-format',[dart,'format','lib/windows_desktop_control.dart','test/windows_desktop_control_test.dart'],'packages/info_core')
 run('cli-format',[dart,'format','lib/desktop_control.dart','bin/info.dart','test/desktop_control_test.dart'],'packages/info_cli')
 run('desktop-format',[dart,'format','lib/desktop_bootstrap.dart','lib/desktop_runtime.dart','test/desktop_bootstrap_test.dart','test/desktop_runtime_test.dart'],'apps/desktop')
 for p in ['info_core','info_cli']:
  run(p+'-pub',[dart,'pub','get','--enforce-lockfile','--offline'],'packages/'+p)
  run(p+'-analyze',[dart,'analyze','--fatal-infos'],'packages/'+p)
 run('cli-targeted',[dart,'test','test/desktop_control_test.dart','-r','expanded'],'packages/info_cli')
 run('desktop-pub',[flutter,'pub','get','--enforce-lockfile','--offline'],'apps/desktop')
 run('desktop-analyze',[flutter,'analyze','--fatal-infos','--no-pub'],'apps/desktop')
 run('desktop-targeted',[flutter,'test','--no-pub','test/desktop_bootstrap_test.dart','test/desktop_runtime_test.dart','-r','expanded'],'apps/desktop')
finally:
 bad=[]
 for p,b in locks.items():
  if norm(p.read_bytes())!=norm(b):bad.append(str(p))
  else:p.write_bytes(b)
 (out/'result.json').write_text(json.dumps(dict(phases=phases,unexpectedLocks=bad),indent=2)+'\n',encoding='utf-8')
 assert not bad,bad

