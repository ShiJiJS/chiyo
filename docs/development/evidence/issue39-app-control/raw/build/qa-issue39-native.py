from pathlib import Path
import os,sys,json,subprocess
root=Path.cwd();out=root/'build/qa-issue39'/sys.argv[1];out.mkdir(parents=True,exist_ok=False)
env=os.environ.copy();env.update(PUB_HOSTED_URL='https://pub.flutter-io.cn',FLUTTER_STORAGE_BASE_URL='https://storage.flutter-io.cn')
locks={root/p/'pubspec.lock':(root/p/'pubspec.lock').read_bytes() for p in ['packages/info_core','packages/info_storage','packages/info_cli','apps/desktop']}
norm=lambda b:b.replace(b'https://pub.flutter-io.cn',b'https://pub.dev').replace(b'\r\n',b'\n')
phases=[]
def run(name,cmd,cwd):
    with (out/(name+'.txt')).open('wb') as log:p=subprocess.run(cmd,cwd=cwd,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=300)
    phases.append(dict(phase=name,exitCode=p.returncode));print(json.dumps(phases[-1]),flush=True)
    if p.returncode:print((out/(name+'.txt')).read_text(encoding='utf-8',errors='replace')[-9000:]);raise RuntimeError(name)
try:
    for p,b in locks.items():p.write_bytes(b.replace(b'https://pub.dev',b'https://pub.flutter-io.cn'))
    cmake='C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
    run('build-native-peer',[cmake,'--build','apps/desktop/build/windows/x64','--config','Release','--target','desktop_control_fixture'],root)
    env['INFO_TEST_CONTROL_FIXTURE']=str(root/'apps/desktop/build/windows/x64/runner/control-fixture/Release/info_desktop.exe')
    dart='C:/Users/Todoki/.local/share/flutter/bin/dart.bat'
    run('core-pub',[dart,'pub','get','--enforce-lockfile','--offline'],root/'packages/info_core')
    run('native-control',[dart,'test','test/windows_desktop_control_test.dart','-r','expanded'],root/'packages/info_core')
finally:
    bad=[]
    for p,b in locks.items():
        if norm(p.read_bytes())!=norm(b):bad.append(str(p))
        else:p.write_bytes(b)
    (out/'result.json').write_text(json.dumps(dict(phases=phases,unexpectedLocks=bad),indent=2)+'\n',encoding='utf-8');assert not bad,bad
