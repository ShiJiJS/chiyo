import os,subprocess,pathlib,json,time,socket
out=pathlib.Path(__file__).resolve().parent
installed=pathlib.Path(json.loads((out/'installation.json').read_text())['installed'])
app=installed/'app/info_desktop.app'
env={'HOME':str(pathlib.Path.home()),'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','LANG':'en_US.UTF-8','USER':os.environ['USER'],'LOGNAME':os.environ['USER']}
with (out/'application.txt').open('wb') as log:
 proc=subprocess.Popen([str(app/'Contents/MacOS/info_desktop')],cwd=installed,env=env,stdout=log,stderr=subprocess.STDOUT)
 state={'pid':proc.pid,'app':str(app),'environmentKeys':sorted(env),'path':env['PATH'],'entry':'ordinary packaged main.dart; no injection, no QA identity or test binding','started':time.time()}
 (out/'process.json').write_text(json.dumps(state,ensure_ascii=False,indent=2)+'\n')
 print('INSTALLED_MAIN_PID',proc.pid,flush=True)
 code=proc.wait()
 state['exitCode']=code;state['elapsedSeconds']=round(time.time()-state['started'],3)
 with socket.socket() as s:
  s.settimeout(1);state['endpointClosedAfterExit']=s.connect_ex(('127.0.0.1',47125))!=0
 (out/'exit.json').write_text(json.dumps(state,ensure_ascii=False,indent=2)+'\n')
 print('INSTALLED_MAIN_EXIT',code,'endpointClosed',state['endpointClosedAfterExit'],flush=True)
