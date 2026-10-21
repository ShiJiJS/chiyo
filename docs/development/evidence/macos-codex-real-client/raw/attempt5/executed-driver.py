#!/usr/bin/env python3
"""Real synthetic Codex lifecycle acceptance against macos-codex-live.py.

Requires existing explicit project/hook trust; never installs or trusts hooks.
Only synthetic fixtures. Uses real app-server/model and anonymous CLI stdin.
Owner approval is a QA file controller, not physical owner UI acceptance.
Private proofs stay in memory. No transcript/authentication files are read.
"""
import argparse
import json,os,queue,subprocess,threading,time,hashlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('output',type=Path);parser.add_argument('--project',required=True,type=Path);parser.add_argument('--host',required=True,type=Path)
args=parser.parse_args();OUT=args.output.resolve();OUT.relative_to(ROOT/'build/macos-adaptation');OUT.mkdir(exist_ok=False,parents=True)
PROJECT=args.project.resolve();PROJECT.relative_to(ROOT/'build/macos-adaptation');assert (PROJECT/'preparation.json').is_file()
PREP=json.loads((PROJECT/'preparation.json').read_text());CLI=Path(PREP['bundle'])/'info-codex'
for entry in PREP['files']:assert hashlib.sha256((PROJECT/entry['path']).read_bytes()).hexdigest()==entry['sha256']
CLI.resolve().relative_to(PROJECT.parent);assert CLI.is_file() and not CLI.is_symlink()
host=args.host.resolve();host.relative_to(ROOT/'build/macos-adaptation');CONTROL=json.loads((host/'controller.json').read_text());FIX=Path(CONTROL['root']);assert (FIX/'.qa-owner').read_text()==CONTROL['owner']
EVENTS=[];CALLS=[];RESULTS={'sourceSha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'scope':__doc__};PROOFS={};Q=queue.Queue();COUNTER=0

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
  event={'method':method,'threadId':p.get('threadId'),'turnId':p.get('turnId')}
  if method in ['item/started','item/completed']:event['itemType']=p.get('item',{}).get('type')
  if method in ['hook/started','hook/completed'] or method.startswith('hooks/'):
   run=p.get('run',{});event.update({k:run.get(k) for k in ['id','eventName','status','sourcePath','durationMs']})
  EVENTS.append(event)
 if method=='item/tool/call' and 'id' in m:
  if p.get('tool') not in ['codex_info','consume_synthetic_file']:raise RuntimeError('Unexpected dynamic tool')
  try:
   value=cli(p['arguments'],p['threadId']) if p['tool']=='codex_info' else consume(p['arguments'])
   result={'contentItems':[{'type':'inputText','text':json.dumps(value)}],'success':True}
  except Exception as e:
   RESULTS.setdefault('bridgeErrors',[]).append({'type':type(e).__name__,'tool':p.get('tool'),'command':p.get('arguments',{}).get('command'),'argumentKeys':list(p.get('arguments',{}))});save()
   result={'contentItems':[{'type':'inputText','text':json.dumps({'bridgeError':type(e).__name__})}],'success':False}
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

def new_thread(source='startup'):
 tool={'type':'function','name':'codex_info','description':'Run reviewed info-codex with no command-line arguments; the full JSON argument object is delivered through anonymous stdin. Uses this actual thread CODEX_THREAD_ID. Private association comes only from your real SessionStart hook.','inputSchema':{'type':'object','properties':{'association':{'type':'string'},'command':{'type':'string'},'purpose':{'type':'string'},'fields':{'type':'array','items':{'type':'object','properties':{'itemId':{'type':'string'},'fieldId':{'type':'string'}},'required':['itemId','fieldId'],'additionalProperties':False}},'requestId':{'type':'string'},'itemId':{'type':'string'},'fieldId':{'type':'string'},'protocolVersion':{'type':'integer'},'operationId':{'type':'string'},'deliveryId':{'type':'string'}},'required':['association','command'],'additionalProperties':True}}
 r=request('thread/start',{'sessionStartSource':source,'cwd':str(PROJECT),'approvalPolicy':'never','sandbox':'read-only','model':RESULTS['model'],'dynamicTools':[tool,{'type':'function','name':'consume_synthetic_file','description':'Consume only the exact synthetic managed file path and deliveryId returned by file-fetch in this test. Reads and closes bytes, returning only count and digest; no upload.','inputSchema':{'type':'object','properties':{'path':{'type':'string'},'deliveryId':{'type':'string'}},'required':['path','deliveryId'],'additionalProperties':False}}],'developerInstructions':'This is an explicitly authorized acceptance test using only synthetic Agent Info data. Use only codex_info and consume_synthetic_file; never shell/exec, other tools, agents, authentication files or unrelated files. Follow agent-info-access. Never print a private association in text. Do not invent or search for missing hook context. Report only public request IDs and operation status; do not output private field values. Reviewed ordinary-file reference follows:\n'+(PROJECT/'.agents/skills/agent-info-access/references/information-files.md').read_text()})
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
 request('initialize',{'clientInfo':{'name':'agent_info_synthetic_mac_lifecycle','version':'1.0'},'capabilities':{'experimentalApi':True}});send({'method':'initialized','params':{}})
 hooks=request('hooks/list',{'cwds':[str(PROJECT)]})
 assert len(hooks['data'])==1 and len(hooks['data'][0]['hooks'])==3
 assert all(h['trustStatus']=='trusted' and h['enabled'] for h in hooks['data'][0]['hooks'])
 RESULTS['hookDiscovery']=hooks
 models=request('model/list',{});RESULTS['model']=next(m['model'] for m in models['data'] if m.get('isDefault'));RESULTS['modelSelection']='CLI-advertised default, process only'
 e=new_thread();RESULTS['threadE']=e;save();print('LIFECYCLE_THREAD_READY',flush=True)
 turn(e,'Synthetic real lifecycle acceptance. Use public catalog and your actual hook association. Request only Address of Synthetic Mac server once, purpose "Synthetic real lifecycle acceptance". Stop while pending; no new connections, no private data output.')
 s=owner('status');pending=[r for r in s['requests'] if r['state']=='pending'];assert len(pending)==1;r=pending[0];rid=r['id'];RESULTS['requestE']=rid
 RESULTS['approvedSnapshot']=owner('approve',requestId=rid,fields=[s['addressField']])
 turn(e,'The owner selected its scope. Claim the same request and read the approved Address exactly once. Do not print its value or request anything else.')
 RESULTS['beforeRejoinSnapshot']=owner('status');request('thread/resume',{'threadId':e,'excludeTurns':True});RESULTS['runningRejoinDone']=True
 # This is a real model compaction, not a synthetic hook payload.
 start=len(EVENTS);request('thread/compact/start',{'threadId':e});end=time.monotonic()+300
 while time.monotonic()<end:
  m=receive(max(.1,end-time.monotonic()))
  if m.get('method')=='turn/completed' and m['params'].get('threadId')==e:
   assert m['params']['turn']['status']=='completed';break
  if m.get('method')=='thread/compacted' and m['params'].get('threadId')==e:break
 else:raise TimeoutError('Compaction deadline')
 RESULTS['compactionEvents']=EVENTS[start:];save();print('REAL_COMPACT_COMPLETE',flush=True)
 turn(e,'After compaction, use only the association retained in your context. Read the same approved Address once more under the original request. Never search private files or reconnect silently. Do not print the field value.')
 RESULTS['afterCompactSnapshot']=owner('status')
 f=request('thread/fork',{'threadId':e,'excludeTurns':True})['thread']['id'];RESULTS['threadF']=f
 turn(f,'Fork isolation acceptance. Use only your latest SessionStart association, never an older parent reference. Query status of public request '+rid+' once. Do not make requests or obtain another proof. Report public status only.')
 assert PROOFS.get(f) and PROOFS[f]!=PROOFS[e]
 g=new_thread('clear');RESULTS['threadG']=g
 turn(g,'Clear-source isolation acceptance. Use your own new hook association and query status of public request '+rid+' once. Do not make requests, search for proof or reconnect; report status only.')
 # Leave one pending request in the approved root before true SessionEnd.
 turn(e,'Synthetic pending-request cancellation acceptance. In the same current association, submit one additional request only for Username of Synthetic Mac server, purpose "Synthetic pending cancellation on SessionEnd". Leave it pending. Do not try to read Username or reconnect.')
 RESULTS['beforeEndSnapshot']=owner('status');request('thread/archive',{'threadId':e});RESULTS['afterEndSnapshot']=owner('status')
 RESULTS['endedClaim']=cli({'association':PROOFS[e],'command':'claim','requestId':rid},e,'negative-protocol-probe');assert RESULTS['endedClaim']['status']=='unauthorized'
 request('thread/resume',{'threadId':e,'excludeTurns':True})
 turn(e,'This synthetic root has already received SessionEnd. Query the original request using only the association still in your context. Do not reconnect, search files or create any request. Report public refusal status only.')
 RESULTS['afterEndedResumeSnapshot']=owner('status')
 for tid in [e,f,g]:request('thread/archive',{'threadId':tid})
 RESULTS['completeLifecycleFlow']=True;save();print('LIFECYCLE_COMPLETE',flush=True)
except Exception as e:
 RESULTS['failure']={'type':type(e).__name__,'message':str(e)};save();print('ACCEPTANCE_FAILURE '+type(e).__name__+' '+str(e),flush=True)
finally:
 P.stdin.close()
 try:RESULTS['serverExitCode']=P.wait(timeout=20)
 except subprocess.TimeoutExpired:P.terminate();RESULTS['serverExitCode']=P.wait(timeout=10)
 ERR.close();RESULTS['finalSnapshot']=owner('status');save()
 for proof in PROOFS.values():assert proof.encode() not in (OUT/'real-client-result.json').read_bytes()
 RESULTS['proofReferencesAbsentFromEvidence']=True;save();print('LIFECYCLE_CLIENT_CLOSED',flush=True)
