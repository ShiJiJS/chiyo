#!/usr/bin/env python3
"""Authorized synthetic real-client run. Never persist model context or proofs."""
import json,os,queue,subprocess,threading,time,hashlib
from pathlib import Path
ROOT=Path.cwd(); OUT=ROOT/'build/macos-adaptation/issue49-real-client-1'
OUT=OUT/'attempt3';OUT.mkdir(exist_ok=False)
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
 assert args.get('command') in ['catalog','capabilities','request','status','claim','read','file-fetch','file-status','file-release']
 proc=subprocess.Popen([str(CLI)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,cwd=PROJECT,env=env)
 argv=subprocess.check_output(['/bin/ps','-p',str(proc.pid),'-o','command='])
 assert not args.get('association') or args['association'].encode() not in argv
 stdout,stderr=proc.communicate(json.dumps(args).encode(),timeout=20)
 value=json.loads(stdout)
 assert not stderr
 r=proc
 if args.get('association') and origin=='model':PROOFS[tid]=args['association']
 CALLS.append({'origin':origin,'threadId':tid,'command':args.get('command'),'requestId':args.get('requestId'),'fieldId':args.get('fieldId'),'exitCode':r.returncode,'response':safe_output(value),'separateStdin':True,'argvCount':1,'argvInspectedBeforeStdin':True})
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
  if p.get('tool') not in ['codex_info','consume_synthetic_file']:raise RuntimeError('Unexpected dynamic tool')
  try:
   value=cli(p['arguments'],p['threadId']) if p['tool']=='codex_info' else consume(p['arguments'])
   result={'contentItems':[{'type':'inputText','text':json.dumps(value)}],'success':True}
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
 r=request('thread/start',{'cwd':str(PROJECT),'approvalPolicy':'never','sandbox':'read-only','model':RESULTS['model'],'dynamicTools':[tool,{'type':'function','name':'consume_synthetic_file','description':'Consume only the exact synthetic managed file path and deliveryId returned by file-fetch in this test. Reads and closes bytes, returning only count and digest; no upload.','inputSchema':{'type':'object','properties':{'path':{'type':'string'},'deliveryId':{'type':'string'}},'required':['path','deliveryId'],'additionalProperties':False}}],'developerInstructions':'This is an explicitly authorized acceptance test using only synthetic Agent Info data. Use only codex_info, never shell/exec, other tools, agents, authentication files or unrelated files. Follow agent-info-access. Never print a private association in text. Do not invent or search for missing hook context. Report only public request IDs and operation status; do not output private field values.'})
 return r['thread']['id']

def consume(args):
 deliveries=[c['response'].get('delivery') for c in CALLS if c['command']=='file-fetch' and c['response'].get('status')=='ok']
 d=next((d for d in deliveries if d and d['deliveryId']==args['deliveryId'] and d['path']==args['path']),None)
 assert d and d['byteLength']==1024
 path=Path(d['path']);assert path.is_file() and not path.is_symlink()
 data=path.read_bytes();assert data==bytes((i*37+11)%256 for i in range(1024))
 v={'status':'consumed','bytes':len(data),'sha256':hashlib.sha256(data).hexdigest(),'deliveryId':d['deliveryId'],'readerClosed':True}
 RESULTS.setdefault('consumers',[]).append(v);save();return v

try:
 request('initialize',{'clientInfo':{'name':'agent_info_synthetic_mac_acceptance','version':'1.0'},'capabilities':{'experimentalApi':True}});send({'method':'initialized','params':{}})
 models=request('model/list',{});RESULTS['model']=next(m['model'] for m in models['data'] if m.get('isDefault'));RESULTS['modelSelection']='CLI-advertised default, process only'
 c=new_thread();RESULTS['threadC']=c;save();print('FILE_THREAD_READY',flush=True)
 turn(c,'Use the real SessionStart association, public catalog and file capability check. Submit exactly one request for Attachment of Synthetic ordinary file, purpose "Synthetic Mac real-client file consumption acceptance". Stop when pending; no text read or new approval.')
 s=owner('status');pending=[r for r in s['requests'] if r['state']=='pending'];assert len(pending)==1;r=pending[0];assert r['fields']==[{'itemId':s['fileItem'],'fieldId':s['fileField']}]
 RESULTS['requestC']=r['id'];RESULTS['approvedSnapshot']=owner('approve',requestId=r['id'],fields=[s['fileField']]);print('FILE_APPROVED',flush=True)
 turn(c,'The owner has selected the scope. Claim the same request and fetch the approved ordinary file once with protocolVersion 2 and unique operationId synthetic-file-client-01. Pass the actual delivery.path and deliveryId to consume_synthetic_file. Once the reader has closed, release that same delivery. Do not expose file bytes or create another request.')
 assert len(RESULTS.get('consumers',[]))==1
 fetched=[x for x in CALLS if x['command']=='file-fetch'];released=[x for x in CALLS if x['command']=='file-release'];assert len(fetched)==1 and len(released)==1
 delivery=fetched[0]['response']['delivery'];assert not Path(delivery['path']).exists();RESULTS['releasedPathAbsent']=True
 RESULTS['afterFileSnapshot']=owner('status');print('FILE_CONSUMPTION_COMPLETE',flush=True)
 d=new_thread();RESULTS['threadD']=d
 turn(d,'Use only your own real SessionStart association. Query status of this public request from a different synthetic chat: '+r['id']+'. Stop after one status query; do not request approval or obtain any other association.')
 RESULTS['crossChatClaim']=cli({'association':PROOFS[d],'command':'claim','requestId':r['id']},d,'negative-protocol-probe')
 RESULTS['mismatchedProof']=cli({'association':PROOFS[c],'command':'claim','requestId':r['id']},d,'negative-protocol-probe')
 RESULTS['missingProof']=cli({'association':'','command':'claim','requestId':r['id']},d,'negative-protocol-probe')
 assert RESULTS['crossChatClaim']['status']=='unauthorized';assert RESULTS['mismatchedProof']['status']=='association_unavailable';assert RESULTS['missingProof']['status']=='association_unavailable'
 # A real archive invokes SessionEnd; keep a live grant until this point.
 RESULTS['beforeArchiveSnapshot']=owner('status');RESULTS['archiveC']=request('thread/archive',{'threadId':c});RESULTS['afterArchiveSnapshot']=owner('status')
 RESULTS['endedRead']=cli({'association':PROOFS[c],'command':'claim','requestId':r['id']},c,'negative-protocol-probe');assert RESULTS['endedRead']['status']=='unauthorized'
 RESULTS['archiveD']=request('thread/archive',{'threadId':d});RESULTS['completeFileFlow']=True
except Exception as e:
 RESULTS['failure']={'type':type(e).__name__,'message':str(e)};save();print('ACCEPTANCE_FAILURE '+type(e).__name__+' '+str(e),flush=True)
finally:
 P.stdin.close()
 try:RESULTS['serverExitCode']=P.wait(timeout=20)
 except subprocess.TimeoutExpired:P.terminate();RESULTS['serverExitCode']=P.wait(timeout=10)
 ERR.close();RESULTS['finalSnapshot']=owner('status');save()
 for proof in PROOFS.values():
  assert proof.encode() not in (OUT/'real-client-result.json').read_bytes()
 RESULTS['proofReferencesAbsentFromEvidence']=True;save();print('FILE_CLIENT_CLOSED',flush=True)
