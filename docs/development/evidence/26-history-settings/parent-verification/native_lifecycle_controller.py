"""Native fixture controller. Window actions must be performed with Sky separately."""
import argparse
import json
import os
from pathlib import Path
import queue
import secrets
import socket
import subprocess
import sys
import tempfile
import threading
import time

ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT/'.scratch/native-lifecycle-probe'
DART='C:/Users/Todoki/.local/share/flutter/bin/cache/dart-sdk/bin/dart.exe'
APP=ROOT/'apps/desktop/build/windows/x64/runner/Debug/info_desktop.exe'
BASE.mkdir(exist_ok=True)
run=Path(tempfile.mkdtemp(prefix='synthetic-',dir=BASE)).resolve()
assert run.parent==BASE.resolve()
with socket.socket() as sock:
    sock.bind(('127.0.0.1',0))
    port=sock.getsockname()[1]
assert port!=47125
config=run/'configuration.json'
config.write_text(json.dumps({'root':str(run),'port':port}),encoding='utf-8',newline='\n')
app_log=(run/'app.log').open('w',encoding='utf-8')
events=[]

def record(stage,**facts):
    events.append({'stage':stage,**facts})
    (run/'result.json').write_text(json.dumps({'scope':'real native close/restore-API/settings quit/restart; no toast or tray-click acceptance','events':events},ensure_ascii=False,indent=2),encoding='utf-8',newline='\n')
    print(json.dumps(events[-1],ensure_ascii=False),flush=True)

def status():
    return json.loads((run/'status.json').read_text(encoding='utf-8'))

def launch():
    (run/'status.json').unlink(missing_ok=True)
    p=subprocess.Popen([str(APP),str(config)],cwd=APP.parent,stdout=app_log,stderr=app_log)
    end=time.monotonic()+25
    while time.monotonic()<end:
        assert p.poll() is None, 'Fixture app terminated during startup; see isolated app.log'
        try:
            s=status()
            assert s['state']=='ready' and s['port']==port and s['tray'] is True
            return p
        except (FileNotFoundError,json.JSONDecodeError):
            time.sleep(.1)
    raise AssertionError('Fixture did not become ready')

native=launch()
cli=subprocess.Popen([DART,'run','bin/info.dart','--port',str(port)],cwd=ROOT/'packages/info_cli',stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=(run/'cli-stderr.log').open('w',encoding='utf-8'),text=True,encoding='utf-8',creationflags=subprocess.CREATE_NO_WINDOW)
lines=queue.Queue()
def receive():
    for line in cli.stdout:
        lines.put(json.loads(line))
threading.Thread(target=receive,daemon=True).start()
def command(value):
    cli.stdin.write(json.dumps(value)+'\n')
    cli.stdin.flush()
    return lines.get(timeout=15)
catalog=command({'command':'catalog'})
assert catalog['status']=='ok' and len(catalog['items'])==1
item=catalog['items'][0]
field=item['fields'][0]
assert command({'command':'session','chatLabel':'Native lifecycle synthetic session'})['status']=='ok'
request=command({'command':'request','purpose':'Read only synthetic lifecycle address','fields':[{'itemId':item['id'],'fieldId':field['id']}]})
request_id=request['requestId']
deadline=time.monotonic()+15
while True:
    decision=command({'command':'status','requestId':request_id})
    if decision['status']=='approved': break
    assert time.monotonic()<deadline,decision['status']
    time.sleep(.1)
assert command({'command':'claim','requestId':request_id})['status']=='ok'
read={'command':'read','requestId':request_id,'itemId':item['id'],'fieldId':field['id']}
assert command(read)['status']=='ok'
record('READY_TO_CLOSE',pid=native.pid,port=port,fixtureRoot=str(run),exe=str(APP),tray=True)

for raw in sys.stdin:
    action=raw.strip()
    if action=='background':
        assert native.poll() is None
        assert command(read)['status']=='ok'
        record('BACKGROUND_READ_VERIFIED',processAlive=True,readAllowed=True)
    elif action=='restore':
        nonce=secrets.token_hex(12)
        (run/'control.json').write_text(json.dumps({'action':'show','nonce':nonce}),encoding='utf-8',newline='\n')
        end=time.monotonic()+10
        while status()['controlAck']!=nonce:
            assert time.monotonic()<end
            time.sleep(.1)
        record('REAL_NATIVE_SHOW_API_ACKNOWLEDGED')
    elif action=='exited':
        code=native.wait(timeout=20)
        assert code==0,code
        response=command(read)
        assert response['status']=='service_unavailable',response['status']
        record('SETTINGS_QUIT_VERIFIED',exitCode=code,readStatus=response['status'])
    elif action=='restart':
        native=launch()
        response=command(read)
        assert response['status']=='unauthorized',response['status']
        current=command({'command':'catalog'})
        assert current['status']=='ok' and current['items'][0]['id']==item['id']
        record('RESTART_OLD_CAPABILITY_REJECTED',pid=native.pid,oldReadStatus=response['status'],stableItemId=True)
    elif action=='finish':
        code=native.wait(timeout=20)
        assert code==0
        assert command(read)['status']=='service_unavailable'
        cli.stdin.close()
        assert cli.wait(timeout=15)==0
        record('NATIVE_LIFECYCLE_VERIFIED',exitCode=code)
        break
    else:
        raise AssertionError('Unknown controller action')
