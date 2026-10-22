import pathlib,subprocess,shlex,time,json,os,stat,hashlib
root=pathlib.Path(__file__).resolve().parent
app_pid=5885
worker_path='/Users/jiangxinyi/Documents/Project/agent-info/local/中文 Mac 预览/AgentInfoManage/app/info_desktop.app/Contents/MacOS/info-runtime-worker'
original=root/'private/中文 合成接收器/client'
def proc(pid):
 p=subprocess.run(['/bin/ps','-p',str(pid),'-o','pid=,ppid=,stat=,comm='],capture_output=True,text=True).stdout.strip().split(None,3)
 return None if len(p)!=4 else {'pid':int(p[0]),'parentPID':int(p[1]),'state':p[2],'path':p[3]}
print('OBSERVER_READY',flush=True)
end=time.monotonic()+20
while time.monotonic()<end:
 rows=[p.strip().split(None,3) for p in subprocess.check_output(['/bin/ps','-Ao','pid=,ppid=,stat=,comm='],text=True).splitlines()]
 workers={int(p[0]) for p in rows if len(p)==4 and p[3]==worker_path and int(p[1])==app_pid}
 for row in rows:
  if len(row)!=4 or row[3]!='/usr/bin/ssh' or int(row[1]) not in workers:continue
  pid=int(row[0]);args=shlex.split(subprocess.check_output(['/bin/ps','-p',str(pid),'-o','command='],text=True))
  if not all(x in args for x in ['51692','fixture@127.0.0.1','/bin/sleep','2']):continue
  paths=[args[args.index('-i')+1],args[args.index('-F')+1]]+[x.split('=',1)[1] for x in args if x.startswith(('UserKnownHostsFile=','GlobalKnownHostsFile='))]
  assert len(paths)==4
  for value in paths:
   f=pathlib.Path(value);assert str(f).startswith('/Users/jiangxinyi/Library/Containers/com.example.infoDesktop/Data/tmp/info-managed-') and f.is_file() and not f.is_symlink() and f.stat().st_uid==os.getuid()
  key=pathlib.Path(paths[0]);facts={'app':proc(app_pid),'worker':proc(int(row[1])),'ssh':proc(pid),'observedAt':time.time(),'materialModes':[stat.S_IMODE(pathlib.Path(f).stat().st_mode) for f in paths],'directoryMode':stat.S_IMODE(key.parent.stat().st_mode),'keyMatchesSyntheticOriginal':hashlib.sha256(key.read_bytes()).digest()==hashlib.sha256(original.read_bytes()).digest()}
  fd=os.open(root/'private/live-material.json',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
  with os.fdopen(fd,'w') as f:json.dump({'paths':paths,'directory':str(key.parent),'sshPid':pid,'workerPid':int(row[1])},f)
  (root/'native-chain.json').write_text(json.dumps(facts,indent=2)+'\n');print(json.dumps(facts),flush=True);raise SystemExit(0)
 time.sleep(.025)
raise SystemExit('No exact owned SSH chain observed in 20 seconds')
