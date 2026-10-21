#!/usr/bin/env python3
"""Authorized synthetic real-client run. Never persist model context or proofs."""
import json,os,queue,subprocess,threading,time,hashlib
from pathlib import Path
ROOT=Path.cwd(); OUT=ROOT/'build/macos-adaptation/issue49-real-client-1'
OUT=OUT/'attempt2';OUT.mkdir(exist_ok=False)
PROJECT=ROOT/'build/macos-adaptation/issue49-codex-preparation-1/独立 Mac Codex 验收项目'
PREP=json.loads((PROJECT/'preparation.json').read_text()); CLI=Path(PREP['bundle'])/'info-codex'
CONTROL=json.loads((ROOT/'build/macos-adaptation/issue49-live-host-1/controller.json').read_text()); FIX=Path(CONTROL['root'])
EVENTS=[]; CALLS=[]; RESULTS={}; PROOFS={}; Q=queue.Queue(); COUNTER=0

def save():
 (OUT/'real-client-result.json').write_text(json.dumps({'results':RESULTS,'events':EVENTS,'calls':CALLS},indent=2)+'\n')
def owner(action,**kw):
 indices=[int(p.stem.split('-')[1]) for p in FIX.glob('command-*.json')];n=max(indices,default=0)+1
 p=FIX/f'command-{n}.json';temp=p.with_suffix('.partial');temp.write_text(json.dumps({'owner':CONTROL['owner'],'action':action,**kw}));temp.rename(p)
 end=time.monotonic()+10
 while time.monotonic()<end:
  r=FIX/f'reply-{n}.json'
  if r.exists():return json.loads(r.read_text())
  time.sleep(.05)
 raise TimeoutError('Owner fixture response')

def safe_output(v):
 if isinstance(v,dict):return {k:safe_output(x) for k,x in v.items() if k not in ['association','privateAssociation','secret','token']}
 if isinstance(v,list):return [safe_output(x) for x in v]
 return v

ERR=(OUT/'real-client-stderr.txt').open('wb')
P=subprocess.Popen(['codex','app-server','--stdio','-c','analytics.enabled=false'],cwd=PROJECT,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=ERR)
def reader():
 for line in P.stdout:
  try:Q.put(json.loads(line))
  except Exception:Q.put({'badJson':True})
 Q.put(None)
threading.Thread(target=reader,daemon=True).start()
def send(v):P.stdin.write(json.dumps(v).encode()+b'\n');P.stdin.flush()
def cli(args,tid,origin='model'):
 env=os.environ.copy();env['CODEX_THREAD_ID']=tid
 r=subprocess.run([str(CLI)],input=json.dumps(args).encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,cwd=PROJECT,env=env,timeout=20)
 value=json.loads(r.stdout)
 if args.get('association'):PROOFS[tid]=args['association']
 CALLS.append({'origin':origin,'threadId':tid,'command':args.get('command'),'requestId':args.get('requestId'),'fieldId':args.get('fieldId'),'exitCode':r.returncode,'response':safe_output(value),'separateStdin':True,'argvCount':1})
 save();return value

def receive(timeout=180):
 m=Q.get(timeout=timeout)
 if m is None:raise RuntimeError('Server ended')
 method=m.get('method');p=m.get('params',{})
 if method=='error':
  RESULTS.setdefault('clientErrors',[]).append(p.get('error',{}))
 if method:
  event={'method':method}
  if method in ['hook/started','hook/completed'] or method.startswith('hooks/'):
   run=p.get('run',{});event.update({k:run.get(k) for k in ['id','eventName','status','sourcePath','durationMs']})
  EVENTS.append(event)
 if method=='item/tool/call' and 'id' in m:
  if p.get('tool')!='codex_info':raise RuntimeError('Unexpected dynamic tool')
  try:value=cli(p['arguments'],p['threadId']);result={'contentItems':[{'type':'inputText','text':json.dumps(value)}],'success':True}
  except Exception as e:result={'contentItems':[{'type':'inputText','text':json.dumps({'bridgeError':type(e).__name__})}],'success':False}
  send({'id':m['id'],'result':result})
 elif 'id' in m and method:
  # No execution/approval/user-input tools are authorized in this synthetic chat.
  send({'id':m['id'],'error':{'code':-32601,'message':'This acceptance uses codex_info only'}})
 if 'error' in m:raise RuntimeError('RPC error '+str(m['error'].get('code')))
 save();return m

def request(method,params):
 global COUNTER
 COUNTER+=1;n=COUNTER;send({'id':n,'method':method,'params':params});end=time.monotonic()+90
 while time.monotonic()<end:
  m=receive(max(.1,end-time.monotonic()))
  if m.get('id')==n and 'result' in m:return m['result']
 raise TimeoutError(method)

def turn(tid,text):
 start=len(CALLS)
 r=request('turn/start',{'threadId':tid,'input':[{'type':'text','text':text},{'type':'skill','name':'agent-info-access','path':str(PROJECT/'.agents/skills/agent-info-access/SKILL.md')}]})
 end=time.monotonic()+300
 while time.monotonic()<end:
  m=receive(max(.1,end-time.monotonic()))
  if m.get('method')=='turn/completed' and m['params'].get('threadId')==tid:
   status=m['params']['turn']['status'];RESULTS.setdefault('turns',[]).append({'threadId':tid,'status':status,'calls':len(CALLS)-start});save();assert status=='completed',status;return
 raise TimeoutError('Model turn')

def new_thread():
 tool={'type':'function','name':'codex_info','description':'Run reviewed info-codex with no command-line arguments; the full JSON argument object is delivered through anonymous stdin. Uses this actual thread CODEX_THREAD_ID. Private association comes only from your real SessionStart hook.','inputSchema':{'type':'object','properties':{'association':{'type':'string'},'command':{'type':'string'},'purpose':{'type':'string'},'fields':{'type':'array','items':{'type':'object','properties':{'itemId':{'type':'string'},'fieldId':{'type':'string'}},'required':['itemId','fieldId'],'additionalProperties':False}},'requestId':{'type':'string'},'itemId':{'type':'string'},'fieldId':{'type':'string'}},'required':['association','command'],'additionalProperties':True}}
 r=request('thread/start',{'cwd':str(PROJECT),'approvalPolicy':'never','sandbox':'read-only','model':'gpt-6-astra','dynamicTools':[tool],'developerInstructions':'This is an explicitly authorized acceptance test using only synthetic Agent Info data. Use only codex_info, never shell/exec, other tools, agents, authentication files or unrelated files. Follow agent-info-access. Never print a private association in text. Do not invent or search for missing hook context. Report only public request IDs and operation status; do not output private field values.'})
 return r['thread']['id']

try:
 request('initialize',{'clientInfo':{'name':'agent_info_synthetic_mac_acceptance','version':'1.0'},'capabilities':{'experimentalApi':True}});send({'method':'initialized','params':{}})
 hooks=request('hooks/list',{'cwds':[str(PROJECT)]});(OUT/'hook-discovery-after.json').write_text(json.dumps(hooks,indent=2)+'\n')
 a=new_thread();RESULTS['threadA']=a;save();print('THREAD_A_READY',flush=True)
 turn(a,'Use the actual SessionStart association and the agent-info-access skill. Inspect the public catalog, then submit exactly one information access request for both Address and Username fields of Synthetic Mac server, purpose "Synthetic Mac real-client partial approval acceptance". Do not read values. Stop after reporting that request is pending; the owner fixture will select the approved scope separately.')
 s=owner('status');pending=[r for r in s['requests'] if r['state']=='pending'];assert len(pending)==1,'One real pending request required';r=pending[0];assert len(r['fields'])==2
 RESULTS['requestA']=r['id'];RESULTS['pendingSnapshot']=s;save();print('REAL_REQUEST_PENDING',flush=True)
 approved=owner('approve',requestId=r['id'],fields=[s['addressField']]);RESULTS['approvedSnapshot']=approved
 turn(a,'The synthetic owner has now made its selection. Query the same request, claim it, read the approved Address field twice in separate calls under the same request, and explain that Username was excluded. Respect the selected scope; do not request new approval or print the value.')
 reads=[c for c in CALLS if c['threadId']==a and c['command']=='read'];assert len(reads)==2,'Two independent model reads required';assert all(c['fieldId']==s['addressField'] for c in reads)
 negative=cli({'association':PROOFS[a],'command':'read','requestId':r['id'],'itemId':s['textItem'],'fieldId':s['usernameField']},a,'negative-protocol-probe');RESULTS['unapprovedFieldResult']=safe_output(negative)
 b=new_thread();RESULTS['threadB']=b;save();print('THREAD_B_READY',flush=True)
 turn(b,'Use only your own SessionStart association. Cross-chat isolation acceptance: query status of public request ID '+r['id']+' from a separate synthetic chat. Do not obtain another chat proof, make requests, claim access or read information; report whether the request is accessible.')
 revoked=owner('revoke',requestId=r['id']);RESULTS['revokedSnapshot']=revoked
 turn(a,'Continue the original synthetic task: try reading Address once under the existing request, without a new request or approval. If access has ended, stop and report its status. Do not output the field value.')
 RESULTS['afterSnapshot']=owner('status');RESULTS['completeBusinessFlow']=True;print('BUSINESS_FLOW_COMPLETE',flush=True)
 # Archive is exercised as the formal API action; hook observation determines semantics.
 RESULTS['archiveA']=request('thread/archive',{'threadId':a});RESULTS['archiveB']=request('thread/archive',{'threadId':b});RESULTS['afterArchiveSnapshot']=owner('status');save()
except Exception as e:
 RESULTS['failure']={'type':type(e).__name__,'message':str(e)};save();print('ACCEPTANCE_FAILURE '+type(e).__name__+' '+str(e),flush=True)
finally:
 P.stdin.close()
 try:RESULTS['serverExitCode']=P.wait(timeout=20)
 except subprocess.TimeoutExpired:P.terminate();RESULTS['serverExitCode']=P.wait(timeout=10)
 ERR.close();RESULTS['finalSnapshot']=owner('status');save();print('CLIENT_CLOSED',flush=True)
