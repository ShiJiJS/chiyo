import os,sys,json,subprocess,pathlib,datetime
out=pathlib.Path(__file__).resolve().parent
cli=pathlib.Path('/Users/jiangxinyi/Documents/Project/agent-info/local/中文 Mac 预览/AgentInfoManage/cli/info')
env={'HOME':str(pathlib.Path.home()),'PATH':'/usr/bin:/bin','LANG':'en_US.UTF-8'}
with (out/'cli-stderr.txt').open('w') as err:
 p=subprocess.Popen([str(cli),'--port','47125'],cwd=cli.parent,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=err,text=True,bufsize=1)
 (out/'cli-process.json').write_text(json.dumps({'pid':p.pid,'executable':str(cli),'environmentKeys':sorted(env),'PATH':env['PATH']},indent=2)+'\n')
 try:
  for line in sys.stdin:
   if not line.strip():continue
   command=json.loads(line);p.stdin.write(json.dumps(command)+'\n');p.stdin.flush();result=json.loads(p.stdout.readline())
   with (out/'public-client.jsonl').open('a') as log:log.write(json.dumps({'at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'input':command,'result':result},ensure_ascii=False)+'\n')
   print(json.dumps(result,ensure_ascii=False),flush=True)
 finally:
  p.stdin.close();code=p.wait(timeout=10);(out/'cli-exit.json').write_text(json.dumps({'exitCode':code})+'\n');print('PUBLIC_CLI_EXIT',code,flush=True)
