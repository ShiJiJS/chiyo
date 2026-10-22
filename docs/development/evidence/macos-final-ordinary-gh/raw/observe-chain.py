from pathlib import Path
import subprocess,time,json,shlex
root=Path(__file__).resolve().parent
app_pid=6826
package='/Users/jiangxinyi/Documents/Project/agent-info/local/中文 Mac 预览/AgentInfoManage/app/info_desktop.app/Contents/'
worker_path=package+'MacOS/info-runtime-worker'
gh_path=package+'Resources/ThirdParty/gh/bin/gh'
def proc(pid):
 p=subprocess.run(['/bin/ps','-p',str(pid),'-o','pid=,ppid=,stat=,comm='],capture_output=True,text=True).stdout.strip().split(None,3)
 return None if len(p)!=4 else {'pid':int(p[0]),'parentPID':int(p[1]),'state':p[2],'path':p[3]}
print('OBSERVER_READY',flush=True)
end=time.monotonic()+20
while time.monotonic()<end:
 rows=[p.strip().split(None,3) for p in subprocess.check_output(['/bin/ps','-Ao','pid=,ppid=,stat=,comm='],text=True).splitlines()]
 workers={int(p[0]) for p in rows if len(p)==4 and p[3]==worker_path and int(p[1])==app_pid}
 for row in rows:
  if len(row)!=4 or row[3]!=gh_path or int(row[1]) not in workers:continue
  pid=int(row[0]);command=subprocess.check_output(['/bin/ps','-p',str(pid),'-o','command='],text=True)
  if not command.rstrip().endswith(' api user'):continue
  facts={'app':proc(app_pid),'worker':proc(int(row[1])),'gh':proc(pid),'observedAt':time.time(),'targetArguments':['api','user'],'environmentNotRead':True}
  (root/'native-chain.json').write_text(json.dumps(facts,ensure_ascii=False,indent=2)+'\n');print(json.dumps(facts),flush=True);raise SystemExit(0)
 time.sleep(.025)
raise SystemExit('No exact owned GH api user chain observed in 20 seconds')
