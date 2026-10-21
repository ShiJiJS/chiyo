from pathlib import Path
import json
import subprocess
import sys
import time

root = Path('/Users/jiangxinyi/Documents/Project/agent-info')
output = root / 'build/macos-adaptation/issue44-matrix-20261022'
receiver_output = output / 'base-receiver-regression'
aws = root / 'local/中文 Mac 预览/AgentInfoManage/app/info_desktop.app/Contents/Resources/ThirdParty/aws-cli/aws'
facts = {'cases': [], 'scope': 'Direct actual CLI fixture regression; not sandbox acceptance'}
with (output / 'base-receiver-regression.log').open('wb') as log:
    receiver = subprocess.Popen([sys.executable, str(root / 'scripts/qa/macos-aws-receiver.py'),
                                 str(receiver_output)], stdout=log, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 10
        ready = receiver_output / 'fixture.json'
        while not ready.exists():
            assert receiver.poll() is None and time.monotonic() < deadline
            time.sleep(.05)
        port = json.loads(ready.read_text())['port']
        cases = [
            ('sts', ['sts', 'get-caller-identity'], 0),
            ('put', ['ssm', 'put-parameter', '--name', '/fixture/matrix-regression',
                     '--value', 'synthetic-regression', '--type', 'String'], 0),
            ('get', ['ssm', 'get-parameter', '--name', '/fixture/matrix-regression'], 0),
            ('wrong-secret', ['ssm', 'get-parameter', '--name', '/fixture/matrix-regression'], 254),
        ]
        for name, arguments, expected in cases:
            environment = {'HOME': str(output / 'driver-smoke'), 'PATH': '/usr/bin:/bin',
                           'AWS_ACCESS_KEY_ID': 'TEST_ACCESS_ONLY',
                           'AWS_SECRET_ACCESS_KEY': 'WRONG_SYNTHETIC_SECRET' if name == 'wrong-secret' else 'SYNTHETIC_NOT_A_REAL_SECRET',
                           'AWS_EC2_METADATA_DISABLED': 'true'}
            command = [str(aws), *arguments, '--region', 'us-east-1', '--endpoint-url',
                       f'http://127.0.0.1:{port}', '--no-cli-pager']
            result = subprocess.run(command, cwd=output, env=environment,
                                    capture_output=True, timeout=30)
            (output / f'regression-{name}.stdout.txt').write_bytes(result.stdout)
            (output / f'regression-{name}.stderr.txt').write_bytes(result.stderr)
            assert result.returncode == expected, (name, result.returncode)
            if name == 'get':
                assert json.loads(result.stdout)['Parameter']['Value'] == 'synthetic-regression'
            facts['cases'].append({'name': name, 'exit': result.returncode, 'expectedExit': expected})
        counts = json.loads((receiver_output / 'receiver-result.json').read_text())
        assert counts['valid'] == 3 and counts['invalid'] == 1
        facts['receiver'] = counts
    finally:
        receiver.terminate()
        facts['receiverExit'] = receiver.wait(timeout=10)
(output / 'receiver-regression.json').write_text(json.dumps(facts, indent=2) + '\n')
print(json.dumps(facts, indent=2))
