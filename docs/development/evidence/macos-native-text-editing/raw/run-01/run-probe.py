from pathlib import Path
import subprocess,json,os,time,sys
out=Path(__file__).resolve().parent
app=out/'source/apps/desktop/build/macos/Build/Products/Release/MacEditingProbe.app'
variant = 'panel-baseline' if '--native-baseline' in sys.argv else 'probe'
env={'HOME':str(Path.home()),'PATH':'/usr/bin:/bin','LANG':'en_US.UTF-8'}
if variant == 'panel-baseline': env['INFO_QA_NATIVE_EDITING']='disabled'
with (out/(variant+'-runtime.txt')).open('w') as log:
 p=subprocess.Popen([str(app/'Contents/MacOS/MacEditingProbe')],env=env,stdout=log,stderr=subprocess.STDOUT,cwd=out)
 (out/(variant+'-process.json')).write_text(json.dumps({'pid':p.pid,'app':str(app),'noDatabaseOrKeychainCalls':True,'started':time.time()},indent=2)+'\n');print('PROBE_PID',p.pid,flush=True)
 code=p.wait();(out/(variant+'-exit.json')).write_text(json.dumps({'exitCode':code})+'\n');print('PROBE_EXIT',code,flush=True)
