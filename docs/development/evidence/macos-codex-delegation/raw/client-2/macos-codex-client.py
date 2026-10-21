#!/usr/bin/env python3
"""Real synthetic Codex lifecycle acceptance against macos-codex-live.py.

Requires existing explicit project/hook trust; never installs or trusts hooks.
Only synthetic fixtures. Uses real app-server/model and anonymous CLI stdin.
Owner approval is a QA file controller, not physical owner UI acceptance.
Private proofs stay in memory. No transcript/authentication files are read.
"""
import argparse
import secrets,socket,signal
import json,os,queue,subprocess,threading,time,hashlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--case',choices=['lifecycle','credential','expiry-restart','transport-resume','delegation'],default='lifecycle');parser.add_argument('--resume-ended',help='Public ID of an ended synthetic chat from this project; only test unarchive/resume refusal');parser.add_argument('output',type=Path);parser.add_argument('--project',required=True,type=Path);parser.add_argument('--host',required=True,type=Path)
args=parser.parse_args();OUT=args.output.resolve();OUT.relative_to(ROOT/'build/macos-adaptation');OUT.mkdir(exist_ok=False,parents=True)
PROJECT=args.project.resolve();PROJECT.relative_to(ROOT/'build/macos-adaptation');assert (PROJECT/'preparation.json').is_file()
PREP=json.loads((PROJECT/'preparation.json').read_text());CLI=Path(PREP['bundle'])/'info-codex'
for entry in PREP['files']:assert hashlib.sha256((PROJECT/entry['path']).read_bytes()).hexdigest()==entry['sha256']
CLI.resolve().relative_to(PROJECT.parent);assert CLI.is_file() and not CLI.is_symlink()
host=args.host.resolve();host.relative_to(ROOT/'build/macos-adaptation');CONTROL=json.loads((host/'controller.json').read_text());FIX=Path(CONTROL['root']);assert (FIX/'.qa-owner').read_text()==CONTROL['owner']
EVENTS=[];CALLS=[];RESULTS={'sourceSha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'scope':__doc__};PROOFS={};DELEGATED={};Q=queue.Queue();COUNTER=0

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
WS=None;token=None;token_file=None
if args.case=='transport-resume':
 from websockets.sync.client import connect
 with socket.socket() as listener:
  listener.bind(('127.0.0.1',0));port=listener.getsockname()[1]
 endpoint='ws://127.0.0.1:'+str(port);token=secrets.token_urlsafe(48);token_file=OUT/'transport-token.private'
 fd=os.open(token_file,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
 with os.fdopen(fd,'w') as f:f.write(token)
 P=subprocess.Popen(['codex','app-server','--listen',endpoint,'--ws-auth','capability-token','--ws-token-file',str(token_file),'-c','analytics.enabled=false'],cwd=PROJECT,stdout=subprocess.DEVNULL,stderr=ERR)
 def connect_transport():
  end=time.monotonic()+30
  while time.monotonic()<end:
   try:return connect(endpoint,additional_headers={'Authorization':'Bearer '+token},open_timeout=2,max_size=16*1024*1024)
   except OSError:
    assert P.poll() is None;time.sleep(.1)
  raise TimeoutError('Owned loopback WebSocket startup')
 WS=connect_transport()
else:
 config=['-c','agents.max_concurrent_threads_per_session=1','-c','agents.max_depth=1'] if args.case=='delegation' else []
 P=subprocess.Popen(['codex','app-server','--stdio','-c','analytics.enabled=false',*config],cwd=PROJECT,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=ERR)
def reader(channel):
 try:
  for line in channel:
   try:Q.put(json.loads(line))
   except Exception:Q.put({'badJson':True})
 except Exception as error:
  RESULTS.setdefault('readerClosures',[]).append({'errorType':type(error).__name__})
 finally:Q.put(None)
READER=threading.Thread(target=reader,args=(WS if WS is not None else P.stdout,),daemon=True);READER.start()
def send(v):
 data=json.dumps(v)
 if WS is not None:WS.send(data)
 else:P.stdin.write(data.encode()+b'\n');P.stdin.flush()

def cli(args,tid,origin='model'):
 env=os.environ.copy();env['CODEX_THREAD_ID']=tid
 assert args.get('command') in ['catalog','capabilities','request','status','claim','read','file-fetch','file-status','file-release','credential-catalog','request-use','run-use','operation-status','execution-status','execution-output','cleanup-use','delegate']
 if args.get('command')=='delegate':
  assert globals()['args'].case=='delegation' and tid==RESULTS['delegationRoot']
  assert args.get('childChatId')==RESULTS['delegationChild'] and not DELEGATED
 if args.get('launch'):
  launch=args['launch'];assert launch['receiver']=='ssh_identity' and launch['executable']=='/usr/bin/ssh'
  assert launch['argv'][-1] in ['/usr/bin/true','/usr/bin/false'] and launch['env']=={}
 proc=subprocess.Popen([str(CLI)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,cwd=PROJECT,env=env)
 argv=subprocess.check_output(['/bin/ps','-p',str(proc.pid),'-o','command='])
 assert not args.get('association') or args['association'].encode() not in argv
 stdout,stderr=proc.communicate(json.dumps(args).encode(),timeout=20)
 value=json.loads(stdout)
 assert not stderr
 if args.get('command')=='delegate' and value.get('privateAssociation'):
  DELEGATED[args['childChatId']]=value['privateAssociation']
 r=proc
 if args.get('association') and origin=='model':PROOFS[tid]=args['association']
 CALLS.append({'origin':origin,'threadId':tid,'command':args.get('command'),'requestId':args.get('requestId'),'fieldId':args.get('fieldId'),'operationId':args.get('operationId'),'exitCode':r.returncode,'response':safe_output(value),'separateStdin':True,'argvCount':1,'argvInspectedBeforeStdin':True})
 save();return value

def receive(timeout=180):
 m=Q.get(timeout=timeout)
 if m is None:raise RuntimeError('Server ended')
 method=m.get('method');p=m.get('params',{})
 if method=='item/completed' and p.get('item',{}).get('type')=='agentMessage':
  report=p['item'].get('text','')
  assert all(proof not in report for proof in [*PROOFS.values(),*DELEGATED.values()])
  RESULTS.setdefault('agentReportChecks',[]).append({'threadId':p.get('threadId'),'turnId':p.get('turnId'),'reconnectMentioned':any(word in report.lower() for word in ['reconnect','重新连接','重新接入']),'proofReferenceAbsent':True})
 if method=='error':
  RESULTS.setdefault('clientErrors',[]).append(p.get('error',{}))
 if method:
  event={'method':method,'threadId':p.get('threadId'),'turnId':p.get('turnId') or p.get('turn',{}).get('id')}
  if method=='turn/completed':event['turnStatus']=p.get('turn',{}).get('status')
  if method in ['item/started','item/completed']:event['itemType']=p.get('item',{}).get('type')
  item=p.get('item',{})
  if item.get('type')=='collabAgentToolCall':
   event.update({key:item.get(key) for key in ['tool','senderThreadId','receiverThreadIds','status']})
   event['agentStatuses']={key:value.get('status') for key,value in item.get('agentsStates',{}).items()}
   # Do not retain collab prompt text: send_input privately carries the child proof.
   if method=='item/completed' and item.get('tool')=='spawnAgent' and item.get('status')=='completed':
    assert args.case=='delegation' and item.get('senderThreadId')==RESULTS['delegationRoot']
    assert not RESULTS.get('delegationChild') and len(item['receiverThreadIds'])==1
    RESULTS['delegationChild']=item['receiverThreadIds'][0]
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
 if 'error' in m:
  RESULTS.setdefault('rpcErrors',[]).append(m['error']);save()
  raise RuntimeError('RPC error '+str(m['error'].get('code')))
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
 tool={'type':'function','name':'codex_info','description':'Run reviewed info-codex with no command-line arguments; the full JSON argument object is delivered through anonymous stdin. Uses this actual thread CODEX_THREAD_ID. Private association comes only from your real SessionStart hook.','inputSchema':{'type':'object','properties':{'association':{'type':'string'},'command':{'type':'string'},'purpose':{'type':'string'},'fields':{'type':'array','items':{'type':'object','properties':{'itemId':{'type':'string'},'fieldId':{'type':'string'}},'required':['itemId','fieldId'],'additionalProperties':False}},'requestId':{'type':'string'},'itemId':{'type':'string'},'fieldId':{'type':'string'},'protocolVersion':{'type':'integer'},'operationId':{'type':'string'},'deliveryId':{'type':'string'},'executionId':{'type':'string'},'credentials':{'type':'array','items':{'type':'object','properties':{'alias':{'type':'string'},'credentialId':{'type':'string'},'version':{'type':'integer'}},'required':['alias','credentialId','version'],'additionalProperties':False}},'readFields':{'type':'array','items':{'type':'object','properties':{'itemId':{'type':'string'},'fieldId':{'type':'string'}},'required':['itemId','fieldId'],'additionalProperties':False}},'launch':{'type':'object','properties':{'receiver':{'type':'string'},'executable':{'type':'string'},'cwd':{'type':'string'},'env':{'type':'object'},'argv':{'type':'array','items':{'oneOf':[{'type':'string'},{'type':'object','properties':{'file':{'type':'string'}},'required':['file'],'additionalProperties':False}]}}},'required':['receiver','executable','cwd','env','argv'],'additionalProperties':False}},'required':['association','command'],'additionalProperties':True}}
 instructions='This is an explicitly authorized acceptance test using only synthetic Agent Info data. Use only codex_info and consume_synthetic_file; never shell/exec, other tools, agents, authentication files or unrelated files.'
 if args.case=='delegation':
  instructions='This is a user-arranged, explicitly authorized real parent/child acceptance with synthetic data only. The root may spawn EXACTLY ONE real child, then privately send_input to that SAME child and wait for it. Never spawn a second child, close/reopen children, or let a child spawn grandchildren. Use only codex_info and the built-in spawn_agent/send_input/wait tools; no shell/exec, other tools, authentication files or unrelated files. Spawn without fork_context if that option exists. A child initially has no association: wait for the parent to explicitly delegate after its real ID is known. The root uses its own SessionStart reference, calls delegate with the actual child ID, then passes ONLY that child-bound reference directly in the private child task using send_input. Never pass the root reference. No new connection, hook or trust changes. Child completion must leave the root grant active.'
 instructions+=' Follow agent-info-access. Never print a private association in text. Do not invent or search for missing hook context. Report only public request IDs and operation status; do not output private field values. Reviewed ordinary-file reference follows:\n'+(PROJECT/'.agents/skills/agent-info-access/references/information-files.md').read_text()+'\nReviewed credential reference; command injection is supported on this Mac fixture when capabilities advertises it:\n'+(PROJECT/'.agents/skills/agent-info-access/references/credential-use.md').read_text()
 r=request('thread/start',{'sessionStartSource':source,'cwd':str(PROJECT),'approvalPolicy':'never','sandbox':'read-only','model':RESULTS['model'],'dynamicTools':[tool,{'type':'function','name':'consume_synthetic_file','description':'Consume only the exact synthetic managed file path and deliveryId returned by file-fetch in this test. Reads and closes bytes, returning only count and digest; no upload.','inputSchema':{'type':'object','properties':{'path':{'type':'string'},'deliveryId':{'type':'string'}},'required':['path','deliveryId'],'additionalProperties':False}}],'developerInstructions':instructions})
 return r['thread']['id']

def consume(args):
 deliveries=[c['response'].get('delivery') for c in CALLS if c['command']=='file-fetch' and c['response'].get('status')=='ok']
 d=next((d for d in deliveries if d and d['deliveryId']==args['deliveryId'] and d['path']==args['path']),None)
 assert d and d['byteLength']==1024
 path=Path(d['path']);assert path.is_file() and not path.is_symlink()
 data=path.read_bytes();assert data==bytes((i*37+11)%256 for i in range(1024))
 v={'status':'consumed','bytes':len(data),'sha256':hashlib.sha256(data).hexdigest(),'deliveryId':d['deliveryId'],'readerClosed':True}
 RESULTS.setdefault('consumers',[]).append(v);save();return v


def delegation_case():
 previous={r['id'] for r in owner('status')['requests']}
 tid=new_thread();RESULTS['delegationRoot']=tid;save()
 turn(tid,'User-arranged one-child acceptance, first stage: use the actual SessionStart association and catalog. Make exactly ONE ordinary request for Address AND Username of Synthetic Mac server, purpose "Synthetic real parent-child acceptance". Do not spawn yet. Stop while pending. No private values in reports.')
 snapshot=owner('status');pending=[r for r in snapshot['requests'] if r['state']=='pending'];assert len(pending)==1
 rid=pending[0]['id'];RESULTS['delegationRequest']=rid
 RESULTS['delegationApproved']=owner('approve',requestId=rid,fields=[snapshot['addressField']])
 turn(tid,'Claim the same request and read only approved Address once. Do not request anything else or spawn yet. Report only status.')
 baseline=owner('status');grant=next(g for g in baseline['grants'] if g['requestId']==rid);assert grant['active']
 turn(tid,'Now spawn EXACTLY ONE real child. Its initial task is only to acknowledge privately that it awaits an explicitly delegated association; no tools or access yet. After its actual ID is returned, call codex_info delegate using your own association and childChatId. Send that returned child-bound privateAssociation directly to the SAME child with send_input, together with public request '+rid+' and the catalog field IDs. Instruct it to claim that same request, read approved Address exactly once, then attempt excluded Username once under that same request (expect refusal); do not make new requests, reconnect, read files, or spawn agents. Do not give it the root association. Wait for the child result. Do not close the child. Report only public status, never references or values.')
 child=RESULTS['delegationChild'];assert child in DELEGATED and PROOFS.get(child)==DELEGATED[child] and PROOFS[child]!=PROOFS[tid]
 child_reads=[c for c in CALLS if c['origin']=='model' and c['threadId']==child and c['command']=='read']
 assert any(c['fieldId']==snapshot['addressField'] and c['response'].get('status')=='ok' for c in child_reads)
 assert any(c['fieldId']==snapshot['usernameField'] and c['response'].get('status')=='unauthorized' for c in child_reads)
 starts=[e for e in EVENTS if (e.get('eventName') or '').lower()=='subagentstart' and e['method']=='hook/completed'];assert len(starts)==1 and starts[0].get('status')=='completed'
 after=owner('status');same=next(g for g in after['grants'] if g['requestId']==rid)
 assert same['active'] and same['expiresAt']==grant['expiresAt'] and len([r for r in after['requests'] if r['id'] not in previous])==1
 RESULTS['afterChildCompleted']=after
 turn(tid,'The only child completed. Read the originally approved Address once yourself under the same request and original association. No more children, requests or reconnects. Report only status.')
 assert CALLS[-1]['threadId']==tid and CALLS[-1]['command']=='read' and CALLS[-1]['response'].get('status')=='ok'
 # Trigger an actual root interruption through the supported app-server RPC.
 start=len(EVENTS);r=request('turn/start',{'threadId':tid,'input':[{'type':'text','text':'This test turn will immediately be interrupted. Do not call any tools, spawn agents, read information or modify anything.'}]})
 turn_id=r['turn']['id'];request('turn/interrupt',{'threadId':tid,'turnId':turn_id});deadline=time.monotonic()+60
 while not any(e['method']=='turn/completed' and e.get('turnId')==turn_id for e in EVENTS[start:]):
  assert time.monotonic()<deadline;receive(max(.1,deadline-time.monotonic()))
 assert any(e.get('turnId')==turn_id and e.get('turnStatus')=='interrupted' for e in EVENTS[start:])
 RESULTS['rootInterruptEvents']=EVENTS[start:];RESULTS['afterRootInterrupt']=owner('status')
 interrupted=next(g for g in RESULTS['afterRootInterrupt']['grants'] if g['requestId']==rid)
 assert interrupted['active'] and interrupted['expiresAt']==grant['expiresAt']
 turn(tid,'After the tester interrupted the previous turn, read Address once under the original request/reference. Do not create children, requests or a new session. Public status only.')
 assert CALLS[-1]['threadId']==tid and CALLS[-1]['command']=='read' and CALLS[-1]['response'].get('status')=='ok'
 RESULTS['beforeRootEnd']=owner('status');request('thread/archive',{'threadId':tid});RESULTS['afterRootEnd']=owner('status')
 ended=RESULTS['afterRootEnd'];current=[r for r in ended['requests'] if r['id'] not in previous];assert len(current)==1 and current[0]['sessionEnded'] and not any(g['active'] for g in ended['grants'])
 for subject in [tid,child]:
  refusal=cli({'association':PROOFS[subject],'command':'read','requestId':rid,'itemId':snapshot['textItem'],'fieldId':snapshot['addressField']},subject,'post-root-end-protocol-probe')
  assert refusal.get('status')=='unauthorized'
 assert sum(e.get('tool')=='spawnAgent' and e['method']=='item/completed' and e.get('status')=='completed' for e in EVENTS)==1
 assert any((e.get('eventName') or '').lower()=='sessionend' and e['method']=='hook/completed' and e.get('status')=='completed' for e in EVENTS)
 RESULTS['completeDelegationFlow']=True;save();print('REAL_ONE_CHILD_DELEGATION_COMPLETE',flush=True)

def credential_case():
 tid=new_thread();RESULTS['credentialThread']=tid;s=owner('status');ssh=s['ssh']
 blueprint={'receiver':'ssh_identity','executable':'/usr/bin/ssh','argv':['-T','-o','BatchMode=yes','-i',{'file':'ssh_key'},'-p',str(ssh['port']),'fixture@127.0.0.1','/usr/bin/true'],'cwd':ssh['cwd'],'env':{}}
 RESULTS['publicLaunch']=blueprint;save()
 turn(tid,'Synthetic Mac SSH reuse and partial-file approval acceptance. Query capabilities and public credential/catalog metadata. Submit exactly one protocolVersion 2 request-use for Synthetic Codex SSH key, alias ssh_key, version from catalog. Include readFields for Attachment of Synthetic ordinary file and Username of Synthetic Mac server; the owner will select scope. Purpose "Synthetic real Codex SSH reuse and file acceptance". Use exactly this first launch: '+json.dumps(blueprint)+'. Do not start an operation, read data, echo key contents or reconnect. Stop pending.')
 s=owner('status');requests=[r for r in s['credentialRequests'] if r['state']=='pending'];assert len(requests)==1;rid=requests[0]['id'];RESULTS['credentialRequest']=rid
 RESULTS['credentialApprovedSnapshot']=owner('approve-use',requestId=rid);save();print('CREDENTIAL_APPROVED',flush=True)
 turn(tid,'The owner selected the credential and ordinary fields. Inspect status/claim of the same request and respect the final selection. Run two operations under that one request: codex-ssh-true-01 uses the exact first launch; codex-ssh-false-01 changes only its final remote command to /usr/bin/false. Poll execution-status to a recorded terminal state with cleanup complete; cleanup-use may retry cleanup only. Expected exits are 0 and 1. Do not make another request or launch another operation ID. Do not output credentials or their private file path.')
 s=owner('status');executions=[e for e in s['executions'] if e['requestId']==rid];assert len(executions)==2 and sorted(e['exitCode'] for e in executions)==[0,1] and all(e['state']=='exited' and e['cleanup']=='complete' for e in executions)
 RESULTS['afterTwoExecutionsSnapshot']=s;print('TWO_REAL_SSH_EXITS_VERIFIED',flush=True)
 turn(tid,'Check the original codex-ssh-true-01 operation using operation-status with its exact original launch and request. Then deliberately submit the exact same original run-use object with that same operationId once to test replay protection. It must return the original execution with duplicate true, not launch a new command. Finally fetch only the approved Attachment with protocolVersion 2 operationId codex-ssh-file-01, pass actual delivery path/ID to consume_synthetic_file, then file-release after the reader closes. Do not fetch or read excluded Username, create any new request, or run another command.')
 duplicates=[c for c in CALLS if c['threadId']==tid and c['command']=='run-use' and c['response'].get('duplicate')];assert len(duplicates)==1
 assert any(c['threadId']==tid and c['command']=='operation-status' and c['response'].get('executionId')==duplicates[0]['response']['executionId'] for c in CALLS)
 assert len(RESULTS.get('consumers',[]))==1
 after=owner('status');assert len([e for e in after['executions'] if e['requestId']==rid])==2
 before=next(r for r in RESULTS['credentialApprovedSnapshot']['credentialRequests'] if r['id']==rid);current=next(r for r in after['credentialRequests'] if r['id']==rid);assert before['expiresAt']==current['expiresAt'] and current['grantState']=='available'
 RESULTS['afterReplaySnapshot']=after;RESULTS['credentialRevokedSnapshot']=owner('revoke-use',requestId=rid)
 turn(tid,'Continue the synthetic task by trying exactly one new operation codex-ssh-after-revoke using /usr/bin/true and the same original request/launch. If current permission refuses, stop; do not request approval or retry with another ID. This is a revocation refusal check, not a new credential authorization.')
 rejected=[c for c in CALLS if c['threadId']==tid and c['command']=='run-use' and c['operationId']=='codex-ssh-after-revoke'];assert len(rejected)==1 and rejected[0]['response'].get('status')!='accepted'
 RESULTS['credentialFinalSnapshot']=owner('status');assert len([e for e in RESULTS['credentialFinalSnapshot']['executions'] if e['requestId']==rid])==2
 request('thread/archive',{'threadId':tid});RESULTS['completeCredentialFlow']=True;print('CREDENTIAL_FLOW_COMPLETE',flush=True)


def expiry_restart_case():
 tid=new_thread();RESULTS['expiryThread']=tid
 turn(tid,'Natural expiry acceptance. Use public catalog and actual hook association. Submit one request only for Address of Synthetic Mac server, purpose "Synthetic natural sixty-second expiry". Stop pending, do not read or reconnect.')
 snap=owner('status');r=next(r for r in snap['requests'] if r['state']=='pending' and r['chatLabel'].endswith(tid));rid=r['id'];RESULTS['expiryRequest']=rid
 start=time.monotonic();RESULTS['expiryApprovedSnapshot']=owner('approve',requestId=rid,fields=[snap['addressField']],lifetimeSeconds=60)
 turn(tid,'Owner selected the scope. Read Address once under the same original request without printing the value. Do not renew, reconnect or make another request.')
 assert any(c['threadId']==tid and c['command']=='read' and c['response'].get('status')=='ok' for c in CALLS)
 print('NATURAL_EXPIRY_WAIT_STARTED',flush=True)
 announced=-1
 while time.monotonic()-start<62:
  elapsed=int(time.monotonic()-start)
  if elapsed//15!=announced:announced=elapsed//15;print('EXPIRY_REAL_SECONDS='+str(elapsed),flush=True)
  time.sleep(.2)
 RESULTS['naturalElapsedSeconds']=time.monotonic()-start
 turn(tid,'Continue reading Address exactly once using the original request. If the fixed deadline has expired, stop on refusal; do not reconnect, renew or submit any new request. Do not print the value.')
 reads=[c for c in CALLS if c['threadId']==tid and c['command']=='read'];assert len(reads)==2 and reads[-1]['response'].get('status') in ['unauthorized','expired']
 RESULTS['afterExpirySnapshot']=owner('status');g=next(g for g in RESULTS['afterExpirySnapshot']['grants'] if g['requestId']==rid);assert not g['active'];print('NATURAL_EXPIRY_VERIFIED',flush=True)
 current=new_thread();RESULTS['restartThread']=current
 turn(current,'Application restart acceptance. Use public catalog and your actual hook association. Submit exactly one request only for Address of Synthetic Mac server, purpose "Synthetic retained-library real application restart". Stop pending.')
 snap=owner('status');r=next(r for r in snap['requests'] if r['state']=='pending' and r['chatLabel'].endswith(current));restart_rid=r['id'];RESULTS['restartRequest']=restart_rid
 RESULTS['restartApprovedSnapshot']=owner('approve',requestId=restart_rid,fields=[snap['addressField']])
 turn(current,'Owner selected the scope. Read Address once under that same request without printing its value. Keep the same context and request; do not reconnect or make a second request.')
 assert any(c['threadId']==current and c['command']=='read' and c['response'].get('status')=='ok' for c in CALLS)
 before=json.loads((host/'controller.json').read_text());RESULTS['beforeRestartSnapshot']=owner('restart')['status'];deadline=time.monotonic()+90
 while time.monotonic()<deadline:
  state=json.loads((host/'controller.json').read_text())
  if state.get('epoch',1)>before.get('epoch',1):break
  time.sleep(.1)
 else:raise TimeoutError('Real application reopen deadline')
 assert state['pid']!=before['pid'] and state['root']==before['root'];RESULTS['differentApplicationPid']=True;RESULTS['sameLibraryRoot']=True
 after=owner('status');assert after['reopened'] and after['textItem']==snap['textItem'] and after['fileItem']==snap['fileItem'];RESULTS['afterReopenSnapshot']=after
 print('REAL_APPLICATION_REOPENED',flush=True)
 turn(current,'The application has now quit normally and reopened the same encrypted library in a new process. Try reading Address once with only your original retained association and request. Stop when refused; do not search private files, reconnect, renew, or submit another request.')
 reads=[c for c in CALLS if c['threadId']==current and c['command']=='read'];assert len(reads)==2 and reads[-1]['response'].get('status') in ['unauthorized','association_unavailable']
 fresh=new_thread();RESULTS['freshAfterRestartThread']=fresh
 turn(fresh,'After real application restart, verify the retained synthetic library using this new chat and its own real SessionStart association. Inspect catalog and submit one new request for Address of Synthetic Mac server, purpose "Synthetic fresh authorization after restart". Stop pending.')
 now=owner('status');new=next(r for r in now['requests'] if r['state']=='pending' and r['chatLabel'].endswith(fresh));RESULTS['freshAfterRestartRequest']=new['id'];owner('approve',requestId=new['id'],fields=[now['addressField']])
 turn(fresh,'Owner approved this new request. Read Address exactly once under this new authorization without printing it. Do not use prior chats or grants.')
 assert any(c['threadId']==fresh and c['command']=='read' and c['response']=={'status':'ok','value':'synthetic-host.invalid'} for c in CALLS)
 RESULTS['freshAfterRestartSnapshot']=owner('status')
 for t in [tid,current,fresh]:request('thread/archive',{'threadId':t})
 RESULTS['completeExpiryRestartFlow']=True;print('EXPIRY_RESTART_FLOW_COMPLETE',flush=True)



def transport_resume_case():
 global WS,READER,Q
 tid=new_thread();RESULTS['transportThread']=tid;RESULTS['codexServerPidBeforeDisconnect']=P.pid
 turn(tid,'Real authenticated WebSocket disconnect/resume acceptance. Use public catalog and actual hook association. Submit one request only for Address of Synthetic Mac server, purpose "Synthetic actual client transport reconnect". Stop pending.')
 snap=owner('status');r=next(r for r in snap['requests'] if r['state']=='pending' and r['chatLabel'].endswith(tid));rid=r['id'];RESULTS['transportRequest']=rid
 RESULTS['transportApprovedSnapshot']=owner('approve',requestId=rid,fields=[snap['addressField']])
 turn(tid,'The owner selected its scope. Read Address exactly once under the original request without printing the value. Do not reconnect the information service or create a new request.')
 assert any(c['threadId']==tid and c['command']=='read' and c['response'].get('status')=='ok' for c in CALLS)
 original=PROOFS[tid];RESULTS['beforeDisconnectSnapshot']=owner('status');before_hooks=len([e for e in EVENTS if e.get('eventName')=='sessionEnd'])
 WS.close();READER.join(timeout=5);assert not READER.is_alive();RESULTS['actualClientConnectionClosed']=True
 time.sleep(2);assert P.poll() is None
 RESULTS['whileDisconnectedSnapshot']=owner('status');g=next(g for g in RESULTS['whileDisconnectedSnapshot']['grants'] if g['requestId']==rid);assert g['active']
 Q=queue.Queue();WS=connect_transport();READER=threading.Thread(target=reader,args=(WS,),daemon=True);READER.start()
 request('initialize',{'clientInfo':{'name':'agent_info_synthetic_mac_reconnected','version':'1.0'},'capabilities':{'experimentalApi':True}});send({'method':'initialized','params':{}})
 resumed=request('thread/resume',{'threadId':tid,'excludeTurns':True,'model':RESULTS['model']});assert resumed['thread']['cwd']==str(PROJECT)
 turn(tid,'The client transport has disconnected and reconnected to the same still-running Codex server, and this original chat was formally resumed. Use only your association and request already retained in this chat context. Read Address exactly once again. Do not search private files, use --connect, renew or submit another request; do not print the value.')
 reads=[c for c in CALLS if c['threadId']==tid and c['command']=='read'];assert len(reads)==2 and all(c['response'].get('status')=='ok' for c in reads)
 assert PROOFS[tid]==original;RESULTS['sameAssociationFromRetainedContext']=True;RESULTS['codexServerPidAfterReconnect']=P.pid
 RESULTS['afterTransportResumeSnapshot']=owner('status');before=next(g for g in RESULTS['transportApprovedSnapshot']['grants'] if g['requestId']==rid);after=next(g for g in RESULTS['afterTransportResumeSnapshot']['grants'] if g['requestId']==rid);assert before['expiresAt']==after['expiresAt'] and after['active']
 assert len([e for e in EVENTS if e.get('eventName')=='sessionEnd'])==before_hooks
 # Lose only this test chat's exact proof file, without reading or searching it.
 proof_path=Path(PROOFS[tid]);expected_parent=Path.home()/'Library/Application Support/AgentInfo/codex'
 assert proof_path.parent==expected_parent and proof_path.is_file() and not proof_path.is_symlink()
 retained=proof_path.with_name(proof_path.name+'.synthetic-unavailable');assert not retained.exists();proof_path.rename(retained)
 try:
  turn(tid,'Try reading the same Address once under your existing request and retained reference. If the association is unavailable, stop and explain that an explicit user reconnect is needed. Never search association files or use a public chat ID to recover anything. Do not reconnect automatically or create a replacement request.')
  assert CALLS[-1]['threadId']==tid and CALLS[-1]['response'].get('status')=='association_unavailable'
  assert RESULTS['agentReportChecks'][-1]['reconnectMentioned'];RESULTS['missingAssociationRequiresReconnect']=True
 finally:
  # Exact file came from this owned synthetic chat; no capability is exposed.
  assert retained.is_file() and not retained.is_symlink();retained.unlink();RESULTS['ownedUnavailableProofRemoved']=True
 request('thread/archive',{'threadId':tid});RESULTS['completeTransportResumeFlow']=True;print('REAL_TRANSPORT_RESUME_COMPLETE',flush=True)

try:
 request('initialize',{'clientInfo':{'name':'agent_info_synthetic_mac_lifecycle','version':'1.0'},'capabilities':{'experimentalApi':True}});send({'method':'initialized','params':{}})
 hooks=request('hooks/list',{'cwds':[str(PROJECT)]})
 assert len(hooks['data'])==1 and len(hooks['data'][0]['hooks'])==3
 assert all(h['trustStatus']=='trusted' and h['enabled'] for h in hooks['data'][0]['hooks'])
 RESULTS['hookDiscovery']=hooks
 models=request('model/list',{});RESULTS['model']=next(m['model'] for m in models['data'] if m.get('isDefault'));RESULTS['modelSelection']='CLI-advertised default, process only'
 if args.case=='delegation':
  delegation_case()
 elif args.case=='credential':
  credential_case()
 elif args.case=='transport-resume':
  transport_resume_case()
 elif args.case=='expiry-restart':
  expiry_restart_case()
 elif args.resume_ended:
  e=args.resume_ended;RESULTS['threadE']=e;snapshot=owner('status');own=[r for r in snapshot['requests'] if r['chatLabel'].endswith(e)];assert own and all(r['sessionEnded'] for r in own)
  rid=next(r['id'] for r in own if r['approvedFields']);RESULTS['requestE']=rid;RESULTS['beforeResumeSnapshot']=snapshot
  try:request('thread/resume',{'threadId':e,'excludeTurns':True,'model':RESULTS['model']})
  except RuntimeError:
   assert RESULTS['rpcErrors'][-1]['code']==-32600
   RESULTS['archivedResumeRefused']=True
  else:raise AssertionError('Archived thread unexpectedly resumed')
  request('thread/unarchive',{'threadId':e});resumed=request('thread/resume',{'threadId':e,'excludeTurns':True,'model':RESULTS['model']});assert resumed['thread']['cwd']==str(PROJECT)
  turn(e,'This synthetic root already received SessionEnd. Query public original request '+rid+' using only your own association retained in context. Do not reconnect, search files or create any request. Report only the public refusal status.')
  assert any(c['threadId']==e and c['command'] in ['status','claim'] and c['response'].get('status')=='unauthorized' for c in CALLS)
  RESULTS['afterEndedResumeSnapshot']=owner('status');ended=[r for r in RESULTS['afterEndedResumeSnapshot']['requests'] if r['chatLabel'].endswith(e)];assert ended and all(r['sessionEnded'] for r in ended)
  request('thread/archive',{'threadId':e});RESULTS['completeEndedResumeFlow']=True;save();print('ENDED_RESUME_COMPLETE',flush=True)
 else:
  e=new_thread();RESULTS['threadE']=e;save();print('LIFECYCLE_THREAD_READY',flush=True)
  turn(e,'Synthetic real lifecycle acceptance. Use public catalog and your actual hook association. Request only Address of Synthetic Mac server once, purpose "Synthetic real lifecycle acceptance". Stop while pending; no new connections, no private data output.')
  s=owner('status');pending=[r for r in s['requests'] if r['state']=='pending'];assert len(pending)==1;r=pending[0];rid=r['id'];RESULTS['requestE']=rid
  RESULTS['approvedSnapshot']=owner('approve',requestId=rid,fields=[s['addressField']])
  turn(e,'The owner selected its scope. Claim the same request and read the approved Address exactly once. Do not print its value or request anything else.')
  RESULTS['beforeRejoinSnapshot']=owner('status');request('thread/resume',{'threadId':e,'excludeTurns':True,'model':RESULTS['model']});RESULTS['runningRejoinDone']=True
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
  reads=[c for c in CALLS if c['threadId']==e and c['command']=='read'];assert len(reads)==2 and all(c['response'].get('status')=='ok' for c in reads)
  before=next(g for g in RESULTS['approvedSnapshot']['grants'] if g['requestId']==rid);after=next(g for g in RESULTS['afterCompactSnapshot']['grants'] if g['requestId']==rid);assert before['expiresAt']==after['expiresAt'] and after['active']
  f=request('thread/fork',{'threadId':e,'excludeTurns':True,'model':RESULTS['model']})['thread']['id'];RESULTS['threadF']=f
  turn(f,'Fork isolation acceptance. Use only your latest SessionStart association, never an older parent reference. Query status of public request '+rid+' once. Do not make requests or obtain another proof. Report public status only.')
  assert PROOFS.get(f) and PROOFS[f]!=PROOFS[e]
  assert any(c['threadId']==f and c['command']=='status' and c['response'].get('status')=='unauthorized' for c in CALLS)
  g=new_thread('clear');RESULTS['threadG']=g
  turn(g,'Clear-source isolation acceptance. Use your own new hook association and query status of public request '+rid+' once. Do not make requests, search for proof or reconnect; report status only.')
  assert any(c['threadId']==g and c['command']=='status' and c['response'].get('status')=='unauthorized' for c in CALLS)
  # Leave one pending request in the approved root before true SessionEnd.
  turn(e,'Synthetic pending-request cancellation acceptance. In the same current association, submit one additional request only for Username of Synthetic Mac server, purpose "Synthetic pending cancellation on SessionEnd". Leave it pending. Do not try to read Username or reconnect.')
  RESULTS['beforeEndSnapshot']=owner('status');request('thread/archive',{'threadId':e});RESULTS['afterEndSnapshot']=owner('status')
  rootRequests=[x for x in RESULTS['beforeEndSnapshot']['requests'] if x['chatLabel'].endswith(e)];assert len(rootRequests)==2 and {x['state'] for x in rootRequests}=={'approved','pending'}
  ended=[x for x in RESULTS['afterEndSnapshot']['requests'] if x['chatLabel'].endswith(e)];assert all(x['sessionEnded'] for x in ended) and {x['state'] for x in ended}=={'revoked','cancelled'}
  RESULTS['endedClaim']=cli({'association':PROOFS[e],'command':'claim','requestId':rid},e,'negative-protocol-probe');assert RESULTS['endedClaim']['status']=='unauthorized'
  request('thread/unarchive',{'threadId':e})
  request('thread/resume',{'threadId':e,'excludeTurns':True,'model':RESULTS['model']})
  turn(e,'This synthetic root has already received SessionEnd. Query the original request using only the association still in your context. Do not reconnect, search files or create any request. Report public refusal status only.')
  RESULTS['afterEndedResumeSnapshot']=owner('status')
  resumed=[c for c in CALLS if c['threadId']==e][-1];assert resumed['command'] in ['status','claim'] and resumed['response'].get('status')=='unauthorized'
  for tid in [e,f,g]:request('thread/archive',{'threadId':tid})
  RESULTS['completeLifecycleFlow']=True;save();print('LIFECYCLE_COMPLETE',flush=True)
except Exception as e:
 RESULTS['failure']={'type':type(e).__name__,'message':str(e)};save();print('ACCEPTANCE_FAILURE '+type(e).__name__+' '+str(e),flush=True)
finally:
 if WS is not None:
  WS.close();P.send_signal(signal.SIGINT)
 else:P.stdin.close()
 try:RESULTS['serverExitCode']=P.wait(timeout=20)
 except subprocess.TimeoutExpired:P.terminate();RESULTS['serverExitCode']=P.wait(timeout=10)
 ERR.close()
 if token_file is not None:
  assert token.encode() not in (OUT/'real-client-stderr.txt').read_bytes();token_file.unlink();RESULTS['transportTokenRemoved']=True
 RESULTS['finalSnapshot']=owner('status');save()
 for proof in [*PROOFS.values(),*DELEGATED.values()]:assert proof.encode() not in (OUT/'real-client-result.json').read_bytes()
 RESULTS['proofReferencesAbsentFromEvidence']=True;save();print('LIFECYCLE_CLIENT_CLOSED',flush=True)

if not (RESULTS.get('completeLifecycleFlow') or RESULTS.get('completeEndedResumeFlow') or RESULTS.get('completeCredentialFlow') or RESULTS.get('completeExpiryRestartFlow') or RESULTS.get('completeTransportResumeFlow') or RESULTS.get('completeDelegationFlow')):
 raise SystemExit(1)
