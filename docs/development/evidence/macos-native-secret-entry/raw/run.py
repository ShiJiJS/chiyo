from pathlib import Path
import subprocess,json,sys,time,hashlib
out=Path(__file__).resolve().parent;phase=sys.argv[1]
assert phase in ['fixed', 'not-ready']
app=out/'source/apps/desktop/build/macos/Build/Products/Release/MacSecretEntryProbe.app'
exe=app/'Contents/MacOS/MacSecretEntryProbe'
r=subprocess.run(['codesign','--verify','--deep','--strict',str(app)],capture_output=True,text=True);(out/(phase+'-signature.txt')).write_text(r.stdout+r.stderr);assert r.returncode==0
with (out/(phase+'-runtime.txt')).open('w') as log:
 p=subprocess.Popen([str(exe)],cwd=out,env={'HOME':str(Path.home()),'PATH':'/usr/bin:/bin','LANG':'en_US.UTF-8'},stdout=log,stderr=subprocess.STDOUT)
 (out/(phase+'-process.json')).write_text(json.dumps({'pid':p.pid,'app':str(app),'started':time.time(),'executableSha256':hashlib.sha256(exe.read_bytes()).hexdigest(),'syntheticOnly':True},indent=2)+'\n');print('PROBE_PID',p.pid,flush=True)
 code=p.wait();(out/(phase+'-exit.json')).write_text(json.dumps({'exitCode':code})+'\n');print('PROBE_EXIT',code,flush=True)
