import argparse,hashlib,json,os,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--label',default='core');p.add_argument('--red',action='store_true');p.add_argument('--analyze',action='store_true');p.add_argument('tests',nargs='*');a=p.parse_args()
root=Path(__file__).resolve().parents[4];folder=root/'build/qa-issue33';folder.mkdir(parents=True,exist_ok=True);lock=root/'packages/info_core/pubspec.lock';dart=r'C:/Users/Todoki/.local/share/flutter/bin/dart.bat'
head=subprocess.check_output(['git','show','HEAD:packages/info_core/pubspec.lock'],cwd=root)
env=os.environ.copy();env['PUB_HOSTED_URL']='https://pub.flutter-io.cn'
try:
 lock.write_bytes(head.replace(b'https://pub.dev',b'https://pub.flutter-io.cn'))
 for offline in [True,False]:
  cmd=[dart,'pub','get','--enforce-lockfile']+(['--offline'] if offline else [])
  result=subprocess.run(cmd,cwd=lock.parent,env=env,capture_output=True,text=True,encoding='utf-8')
  (folder/(a.label+'-pub.txt')).write_text(result.stdout+result.stderr,encoding='utf-8')
  if result.returncode==0:break
 if result.returncode:raise RuntimeError((result.stdout+result.stderr)[-1500:])
 result=subprocess.run([dart,'test',*a.tests,'--reporter','expanded'],cwd=lock.parent,env=env,capture_output=True,text=True,encoding='utf-8')
 output=result.stdout+result.stderr;(folder/(a.label+'.txt')).write_text(output,encoding='utf-8')
 print('\n'.join(output.splitlines()[-16:] if result.returncode else output.splitlines()[-3:]),flush=True)
 if a.red:
  assert result.returncode!=0 and 'Failed to load' not in output,'Expected behavioral red; got success or compilation error'
 else:
  assert result.returncode==0,'Tests failed; inspect saved output'
 if a.analyze:
  result=subprocess.run([dart,'analyze','--fatal-infos'],cwd=lock.parent,env=env,capture_output=True,text=True,encoding='utf-8');(folder/(a.label+'-analyze.txt')).write_text(result.stdout+result.stderr,encoding='utf-8');print(result.stdout[-200:],flush=True);assert result.returncode==0
 (folder/(a.label+'-environment.json')).write_text(json.dumps({'expectedRed':a.red,'originalLockSha256':hashlib.sha256(head.replace(b'\r\n',b'\n')).hexdigest(),'mirrorOnly':True,'testFiles':a.tests}),encoding='utf-8')
finally:
 subprocess.run(['git','restore','--','packages/info_core/pubspec.lock'],cwd=root,check=True)
