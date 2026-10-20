from pathlib import Path
p=Path('build/qa-issue39-packaged.py');s=p.read_text(encoding='utf-8')
s=s.replace("p.add_argument('--evidence',type=Path,required=True);a=p.parse_args()", "p.add_argument('--evidence',type=Path,required=True);p.add_argument('--tail-only',action='store_true');a=p.parse_args()")
start=s.index("    start('normal');agent=Agent()")
end=s.index("    start('normal')\n    check('old-proof-does-not-revive'",start)
block=s[start:end]
block=block.replace("inspected=json.loads((out/'inspect.txt').read_text(encoding='utf-8').strip().splitlines()[-1]);facts['libraryInspection']=inspected", "inspection_text=(out/'inspect.txt').read_text(encoding='utf-8');inspected=json.loads(inspection_text[inspection_text.index('{\"status\":\"inspected\"'):].strip());facts['libraryInspection']=inspected")
intro="""    if a.tail_only:
        start('normal');agent=Agent()
        end=time.monotonic()+30
        while time.monotonic()<end:
            opened=agent.call('session',chatLabel='Windows生命周期虚构尾段')
            if opened['status']=='ok':break
            time.sleep(.2)
        check('fresh-session',opened['status']=='ok')
        check('session-valid-before-exit',agent.call('session-check')['status']=='ok')
        code,state=control('quit');check('initial-normal-exits',code==0 and state['status']=='exited' and process.wait(timeout=5)==0)
    else:
"""
s=s[:start]+intro+''.join('    '+line if line.strip() else line for line in block.splitlines(True))+s[end:]
s=s.replace("    check('old-proof-does-not-revive',agent.call('read',requestId=request,itemId=fixture['serverId'],fieldId=fixture['addressField'])['status']=='unauthorized')", "    old_status=agent.call('session-check') if a.tail_only else agent.call('read',requestId=request,itemId=fixture['serverId'],fieldId=fixture['addressField'])\n    check('old-proof-does-not-revive',old_status['status']=='unauthorized')")
p.write_text(s,encoding='utf-8')
# Preserve the failed run, separately verify its already-produced inspection JSON.
import json
out=Path('build/qa-issue39/packaged-02');text=(out/'inspect.txt').read_text(encoding='utf-8');j=json.loads(text[text.index('{"status":"inspected"'):]);assert j['allClosed'] and j['grants']==1 and j['items']==2
(out/'inspection-recheck.json').write_text(json.dumps(dict(passed=True,inspection=j,originalRunComplete=False,reason='Dart build-hook prefix caused the Python JSON parser to reject valid inspection stdout'),indent=2)+'\n',encoding='utf-8')
