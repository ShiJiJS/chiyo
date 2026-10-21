from pathlib import Path
import subprocess,json
out=Path(__file__).resolve().parent;src=out/'source';launcher=str(src/'scripts/dev-macos.sh');stages=[]
for label,cwd,args in [('pub-core',src/'packages/info_core',['dart','pub','get','--enforce-lockfile']),('pub-cli',src/'packages/info_cli',['dart','pub','get','--enforce-lockfile']),('pub-storage',src/'packages/info_storage',['dart','pub','get','--enforce-lockfile']),('pub-desktop',src/'apps/desktop',['flutter','pub','get','--enforce-lockfile']),('format-probe',src/'apps/desktop',['dart','format','lib/editing_probe.dart']),('analyze-probe',src/'apps/desktop',['flutter','analyze','--no-pub','--fatal-infos','lib/editing_probe.dart']),('build-probe',src/'apps/desktop',['flutter','build','macos','--release','--no-pub','--target=lib/editing_probe.dart'])]:
 with (out/(label+'.txt')).open('wb') as log:r=subprocess.run([launcher,*args],cwd=cwd,stdout=log,stderr=subprocess.STDOUT,timeout=900)
 stages.append({'label':label,'exitCode':r.returncode,'args':args});(out/'build-stages.json').write_text(json.dumps(stages,indent=2)+'\n');print(label,r.returncode,flush=True)
 if r.returncode:raise SystemExit(r.returncode)
