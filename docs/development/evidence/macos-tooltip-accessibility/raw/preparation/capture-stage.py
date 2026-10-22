from pathlib import Path
import json,time,sys
b=Path.cwd()/'build/macos-adaptation/issue48-ax-state-20261022';run=b/sys.argv[1];stage=sys.argv[2];c=json.loads((run/'controller.json').read_text());root=Path(c['root']);state=json.loads((run/'result.json').read_text());assert (root/'.qa-owner').read_text()==state['bundleIdentifier'].rsplit('.',1)[1]
r=json.loads((root/'edit.json').read_text());events=[]
for line in (run/'logs/edit.txt').read_text().splitlines():
 if line.startswith('QA_ACCESSIBILITY_STATE='):
  events.append(json.loads(line.split('=',1)[1]))
d={'capturedAtEpochSeconds':time.time(),'stage':stage,'CUAObservationNote':sys.argv[3] if len(sys.argv)>3 else '', 'pid':c['pid'],'frameworkLatest':r.get('latest'),'nativeLast':events[-1] if events else None,'nativeEventRecords':len(events)};p=run/'stages';p.mkdir(exist_ok=True);(p/(stage+'.json')).write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n');print(json.dumps({'stage':stage,'frameworkSemantics':r.get('latest',{}).get('semanticsEnabled'),'focus':r.get('latest',{}).get('focusKeys'),'nativeLast':d['nativeLast'],'records':len(events)},ensure_ascii=False))
