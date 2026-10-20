#!/usr/bin/env python3
"""Check real Codex app-server stdin transport, without a thread, hook or model.

A random disposable marker crosses command/exec/write, never command argv.
This proves the standalone transport only, not model-tool or lifecycle delivery.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import queue
import secrets
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    output.relative_to(ROOT / 'build')
    output.mkdir(parents=True, exist_ok=False)
    marker = secrets.token_bytes(64)
    payload = json.dumps({'synthetic': base64.b64encode(marker).decode()}).encode()
    expected = hashlib.sha256(payload).hexdigest()
    probe = output / 'recipient.py'
    probe.write_text('''import hashlib,json,os,sys
print(json.dumps({'phase':'ready','pid':os.getpid()}),flush=True)
data=sys.stdin.buffer.read()
print(json.dumps({'phase':'received','sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data)}),flush=True)
''')
    messages = queue.Queue()
    events = []
    streams = {'stdout': b'', 'stderr': b''}
    result = {'complete': False, 'scope': 'Real standalone app-server command API; no thread, model, trusted hook or real association'}
    with (output / 'server-stderr.txt').open('wb') as errors:
        process = subprocess.Popen(['codex', 'app-server', '--stdio', '-c', 'analytics.enabled=false'],
            cwd=ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors)
        def read_messages():
            for line in process.stdout:
                messages.put(json.loads(line))
            messages.put(None)
        reader = threading.Thread(target=read_messages, daemon=True)
        reader.start()
        def send(value):
            process.stdin.write(json.dumps(value).encode() + b'\n')
            process.stdin.flush()
        def receive(timeout=30):
            item = messages.get(timeout=timeout)
            if item is None:
                raise RuntimeError('App-server ended before response')
            # No input payload or authentication file is written to evidence.
            events.append(item)
            if item.get('method') == 'command/exec/outputDelta':
                data = item['params']
                streams[data['stream']] += base64.b64decode(data['deltaBase64'])
            if 'error' in item:
                raise RuntimeError('RPC error: ' + str(item['error']))
            return item
        def response(identifier):
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                item = receive(max(.1, deadline - time.monotonic()))
                if item.get('id') == identifier:
                    return item['result']
            raise TimeoutError('Response deadline')
        try:
            send({'id': 1, 'method': 'initialize', 'params': {
                'clientInfo': {'name': 'agent_info_mac_qa', 'version': '1.0'},
                'capabilities': {'experimentalApi': False}}})
            initialization = response(1)
            send({'method': 'initialized', 'params': {}})
            send({'id': 2, 'method': 'command/exec', 'params': {
                'command': [str(Path(sys.executable).resolve()), str(probe)], 'cwd': str(output),
                'processId': 'synthetic-stdin', 'streamStdin': True,
                'streamStdoutStderr': True, 'timeoutMs': 30000,
                'sandboxPolicy': {'type': 'readOnly', 'networkAccess': False}}})
            deadline = time.monotonic() + 30
            while b'\n' not in streams['stdout'] and time.monotonic() < deadline:
                item = receive(max(.1, deadline - time.monotonic()))
                if item.get('id') == 2:
                    raise RuntimeError('Recipient ended before stdin gate')
            ready = json.loads(streams['stdout'].splitlines()[0])
            assert ready['phase'] == 'ready'
            # Check the waiting recipient and real app-server before transmission.
            argv = subprocess.check_output(['/bin/ps', '-p', str(ready['pid']) + ',' + str(process.pid), '-o', 'pid=,command='])
            assert marker not in argv and payload not in argv and base64.b64encode(marker) not in argv
            send({'id': 3, 'method': 'command/exec/write', 'params': {
                'processId': 'synthetic-stdin', 'deltaBase64': base64.b64encode(payload).decode(),
                'closeStdin': True}})
            responses = {}
            while not {2, 3}.issubset(responses):
                item = receive()
                if item.get('id') in [2, 3]:
                    responses[item['id']] = item['result']
            assert responses[2]['exitCode'] == 0
            received = json.loads(streams['stdout'].splitlines()[-1])
            assert received == {'phase': 'received', 'sha256': expected, 'bytes': len(payload)}
            assert not streams['stderr']
            result.update(complete=True, client=subprocess.check_output(['codex','--version'], text=True).strip(),
                initialization=initialization, independentStdin=True, separateArgvVerified=True,
                stdinSha256=expected, stdinBytes=len(payload), recipientExitCode=0,
                modelToolAcceptance=False, hooksInstalled=False, threadsCreated=0)
            (output / 'process-argv.txt').write_bytes(argv)
        except Exception as error:
            result['failure'] = {'type': type(error).__name__, 'message': str(error)}
            raise
        finally:
            process.stdin.close()
            try:
                result['serverExitCode'] = process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.terminate()
                result['serverExitCode'] = process.wait(timeout=10)
                result['ownedServerTerminated'] = True
            safe_events = json.dumps(events, ensure_ascii=False, indent=2).encode()
            for data in [safe_events, (output / 'server-stderr.txt').read_bytes()]:
                assert marker not in data and base64.b64encode(marker) not in data
            (output / 'responses.json').write_bytes(safe_events + b'\n')
            (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'complete': result['complete'], 'threadsCreated': 0, 'modelToolAcceptance': False}))


if __name__ == '__main__':
    main()
