from pathlib import Path
import subprocess,json,os,socket
root=Path('/Users/jiangxinyi/Documents/Project/agent-info')
out=root/'build/macos-adaptation/issue44-ordinary-gh-20261023'
exe=root/'local/中文 Mac 预览/AgentInfoManage/app/info_desktop.app/Contents/MacOS/info_desktop'
env={k:os.environ[k] for k in ['HOME','USER','LOGNAME','LANG'] if k in os.environ};env['PATH']='/usr/bin:/bin'
with(out/'ordinary-restored.log').open('wb') as log:
 p=subprocess.Popen([str(exe)],cwd='/',env=env,stdout=log,stderr=subprocess.STDOUT)
 facts={'pid':p.pid,'environmentKeys':sorted(env),'ordinaryMain':True,'qaIdentityOrKeyInjection':False,'previousOrdinaryPid':6826,'previousNormalExit':0,'previousEndpointClosed':True}
 (out/'ordinary-restored.json').write_text(json.dumps(facts,indent=2)+'\n');print('REOPEN_PID',p.pid,flush=True)
 code=p.wait()
 with socket.socket() as s:s.settimeout(1);closed=s.connect_ex(('127.0.0.1',47125))!=0
 facts.update(exit=code,endpointClosed=closed);(out/'ordinary-restored.json').write_text(json.dumps(facts,indent=2)+'\n');print('REOPEN_EXIT',code,closed,flush=True)
