from pathlib import Path
import subprocess,os,json
root=Path.cwd();out=Path(__file__).resolve().parent;src=out/'source';paths=['apps/desktop/lib/credential_dialogs.dart','apps/desktop/lib/desktop_controls.dart'];current={p:(src/p).read_bytes() for p in paths};steps=[]
try:
 for phase in ['baseline','current']:
  for p in paths:(src/p).write_bytes(subprocess.check_output(['git','show','9379dd5:'+p]) if phase=='baseline' else current[p])
  env=os.environ.copy();env['QA_VISUAL_PHASE']=phase;env['QA_VISUAL_OUTPUT']=str(out/'visual')
  with (out/f'visual-{phase}.txt').open('wb') as log:
   r=subprocess.run([str(src/'scripts/dev-macos.sh'),'flutter','test','--no-pub','test/native_secret_visual_probe_test.dart'],cwd=src/'apps/desktop',env=env,stdout=log,stderr=subprocess.STDOUT,timeout=300)
  steps.append({'phase':phase,'exit':r.returncode});assert r.returncode==0,phase
finally:
 for p,data in current.items():(src/p).write_bytes(data)
 (out/'visual-matrix.json').write_text(json.dumps({'steps':steps,'sourceRestoredExact':all((src/p).read_bytes()==data for p,data in current.items())},indent=2)+'\n')
print('visual matrix complete')
