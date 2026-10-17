import json, socket, subprocess, tempfile
from pathlib import Path
root=Path.cwd()
base=root/'.scratch/ax-probe';base.mkdir(parents=True,exist_ok=True)
run=Path(tempfile.mkdtemp(prefix='synthetic-',dir=base)).resolve()
with socket.socket() as s:
    s.bind(('127.0.0.1',0));port=s.getsockname()[1]
config=run/'configuration.json';config.write_text(json.dumps({'root':str(run),'port':port}),encoding='utf-8')
exe=root/'apps/desktop/build/windows/x64/runner/Debug/info_desktop.exe'
with (run/'app.log').open('w',encoding='utf-8') as log:
    p=subprocess.Popen([str(exe),str(config)],cwd=exe.parent,stdout=log,stderr=log)
state={'root':str(run),'pid':p.pid,'port':port,'exe':str(exe)}
(base/'current.json').write_text(json.dumps(state),encoding='utf-8')
print(json.dumps(state))
