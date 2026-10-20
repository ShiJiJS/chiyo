from pathlib import Path
import hashlib,json,os,re,subprocess

root=Path.cwd()
folder=root/'build/qa-issue30'
package=root/'packages/info_cli'
dart='C:/Users/Todoki/.local/share/flutter/bin/dart.bat'
locks={root/p: (root/p).read_bytes() for p in [
    'packages/info_cli/pubspec.lock','packages/info_core/pubspec.lock',
    'packages/info_storage/pubspec.lock','apps/desktop/pubspec.lock']}
env=os.environ.copy()
env['PUB_HOSTED_URL']='https://pub.flutter-io.cn'
env['INFO_TEST_BUNDLE']=str(root/'build/windows-focused-fill-3e98ec6/AgentInfoManage/cli')
env['D35_COMPILED_CLI']=str(root/'build/qa-issue35/bundle-cli/info.exe')
tests=['test/codex_focused_fill_test.dart','test/focused_fill_client_test.dart',
       'test/focused_fill_target_test.dart','test/bundle_preparation_test.dart']
results=[]
try:
    for path,content in locks.items():
        path.write_bytes(content.replace(b'https://pub.dev',b'https://pub.flutter-io.cn'))
    for name,cmd in [
        ('pub',[dart,'pub','get','--enforce-lockfile','--offline']),
        ('analyze',[dart,'analyze','--fatal-infos']),
        ('tests',[dart,'test',*tests,'--reporter','expanded'])]:
        result=subprocess.run(cmd,cwd=package,env=env,capture_output=True,text=True,encoding='utf-8')
        (folder/(name+'.txt')).write_text(result.stdout+result.stderr,encoding='utf-8',newline='\n')
        results.append({'name':name,'exitCode':result.returncode})
        print(name+': '+str(result.returncode),flush=True)
        print('\n'.join((result.stdout+result.stderr).splitlines()[-8:]),flush=True)
        if result.returncode:
            raise RuntimeError(name+' failed')
finally:
    changed=[]
    for path,content in locks.items():
        normalize=lambda x:x.replace(b'https://pub.flutter-io.cn',b'https://pub.dev').replace(b'\r\n',b'\n')
        if path.exists() and normalize(path.read_bytes())==normalize(content):
            path.write_bytes(content)
        else:
            changed.append(str(path.relative_to(root)))
    (folder/'checks.json').write_text(json.dumps({'results':results,'tests':tests,'unexpectedLocks':changed},indent=2)+'\n',encoding='utf-8')
    if changed:
        raise RuntimeError('Unexpected lock edits preserved: '+str(changed))
