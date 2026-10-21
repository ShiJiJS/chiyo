import os,stat,sys,json,shlex,hashlib,pathlib,subprocess,time
root=pathlib.Path(__file__).resolve().parent
phase=sys.argv[1]
controller=root/'private-live-material.json'
app_worker='/Users/jiangxinyi/Documents/Project/agent-info/local/中文 Mac 预览/AgentInfoManage/app/info_desktop.app/Contents/MacOS/info-runtime-worker'
def proc(pid):
 r=subprocess.run(['ps','-p',str(pid),'-o','pid=,ppid=,stat=,comm='],text=True,capture_output=True)
 p=r.stdout.strip().split(None,3)
 return None if len(p)!=4 else {'pid':int(p[0]),'parentPID':int(p[1]),'state':p[2],'path':p[3]}
if phase=='before-quit':
 rows=[line.strip().split(None,3) for line in subprocess.check_output(['ps','-Ao','pid=,ppid=,stat=,comm='],text=True).splitlines()]
 workers=[int(p[0]) for p in rows if len(p)==4 and p[3]==app_worker and int(p[1])==41097]
 candidates=[int(p[0]) for p in rows if len(p)==4 and p[3]=='/usr/bin/ssh' and int(p[1]) in workers]
 selected=[]
 for pid in candidates:
  command=subprocess.check_output(['ps','-p',str(pid),'-o','command='],text=True)
  args=shlex.split(command)
  if '56895' in args and 'fixture@127.0.0.1' in args and '/fixture/wait' in args:selected.append((pid,args))
 assert len(selected)==1,'Exact held synthetic SSH process required'
 pid,args=selected[0];worker=proc(pid)['parentPID'];paths=[args[args.index('-i')+1],args[args.index('-F')+1]]
 for a in args:
  if a.startswith(('UserKnownHostsFile=','GlobalKnownHostsFile=')):paths.append(a.split('=',1)[1])
 assert len(paths)==4
 prefix='/Users/jiangxinyi/Library/Containers/com.example.infoDesktop/Data/tmp/info-managed-'
 for value in paths:
  p=pathlib.Path(value);assert str(p).startswith(prefix) and p.is_file() and not p.is_symlink() and p.resolve()==p and p.stat().st_uid==os.getuid()
 data={'sshPID':pid,'workerPID':worker,'paths':paths,'key':paths[0]}
 fd=os.open(controller,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
 with os.fdopen(fd,'w') as f:json.dump(data,f)
else:
 assert stat.S_IMODE(controller.stat().st_mode)==0o600
 data=json.loads(controller.read_text())
key=pathlib.Path(data['key']);original=root/'中文 SSH 合成目录/正确 SSH 私钥'
files=[pathlib.Path(p) for p in data['paths']]
facts={'phase':phase,'at':time.time(),'ssh':proc(data['sshPID']),'worker':proc(data['workerPID']),'materialFilesPresent':sum(p.is_file() for p in files),'materialModes':[stat.S_IMODE(p.stat().st_mode) if p.exists() else None for p in files],'keyMatchesOriginalSyntheticKey':hashlib.sha256(key.read_bytes()).digest()==hashlib.sha256(original.read_bytes()).digest() if key.exists() else None,'materialDirectoryMode':stat.S_IMODE(key.parent.stat().st_mode) if key.parent.exists() else None}
(root/('hold-'+phase+'.json')).write_text(json.dumps(facts,ensure_ascii=False,indent=2)+'\n');print(json.dumps(facts,ensure_ascii=False))
