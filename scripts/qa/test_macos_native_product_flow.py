"""Exercise QA orchestration only; fake CLI is not product/native evidence."""
import fcntl
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
FLOW = ROOT / 'scripts/qa/macos-native-product-flow.py'


class ProductFlowChecks(unittest.TestCase):
    def setUp(self):
        (ROOT / 'build').mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix='native-flow-check-', dir=ROOT / 'build')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.out = self.root / 'qa'
        self.assertEqual(self.run_flow('prepare').returncode, 0)
        state = json.loads((self.out / 'qa.json').read_text())
        self.connection = self.root / 'profiles' / state['profileName']
        self.connection.mkdir(parents=True)
        (self.connection / 'local-library.json').write_text(json.dumps({'libraryId': 'synthetic-only'}))
        (self.connection / 'agent-connection.json').write_text(json.dumps({
            'role': 'local-agent', 'address': 'http://127.0.0.1:12345', 'serverId': 'local-synthetic-only'}))
        self.cli = self.root / 'fake-cli'
        self.cli.write_text('''#!/usr/bin/python3
import json,sys
from pathlib import Path
r=Path(__file__).parent; state=json.loads((r/'qa/qa.json').read_text()); args=sys.argv[1:]
with (r/'calls.jsonl').open('a') as f: f.write(json.dumps(args)+'\\n')
key=' '.join(args[:2]); code=0
if key=='chat start':
 Path(args[args.index('--context-out')+1]).write_text('{}'); data={'status':'created'}
elif args[0]=='doctor': data={'fill':{'native':{'available':True}}}
elif key=='credentials list': data={'credentials':[{'name':state['credentialName'],'credentialId':'synthetic','version':1,'form':'string','availability':'available'}]}
elif key=='fill targets': data={'targets':[{'targetId':'synthetic-opaque-target-reference','fieldLabel':state['archiveName']}]}
elif key=='fill request': data={'status':'pending','requestId':'synthetic-request'}; code=6
elif key=='requests wait': data={'status':'approved'}
elif key=='fill run': data={'executionState':'unknown','operationId':state['runOperation']}; code=7
elif key=='operations show': data={'status':'ok','executionState':'unknown','operationId':state['runOperation']}
else: raise RuntimeError('unexpected fake command')
print(json.dumps({'ok':code==0,'data':data})); sys.exit(code)
''')
        self.cli.chmod(0o700)

    def run_flow(self, stage, *args):
        return subprocess.run([sys.executable, FLOW, stage, self.out, *map(str, args)], capture_output=True, text=True)

    def request(self):
        result = self.run_flow('request', '--cli', self.cli, '--connection-directory', self.connection)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_pending_request_and_unknown_write_are_not_replayed(self):
        self.request()
        self.assertEqual(self.run_flow('run').returncode, 0)
        self.assertNotEqual(self.run_flow('run').returncode, 0)
        self.assertEqual(self.run_flow('status').returncode, 0)
        calls = [json.loads(x) for x in (self.root / 'calls.jsonl').read_text().splitlines()]
        self.assertEqual(sum(x[:2] == ['fill', 'run'] for x in calls), 1)
        self.assertEqual(calls[-1][:2], ['operations', 'show'])
        shutil.copyfile(self.out / 'input/native-background-proof.txt', self.out / 'native-background-proof.txt')
        self.assertNotEqual(self.run_flow('business').returncode, 0, 'unknown cannot become business success')

    def test_default_profile_is_refused_before_any_cli_call(self):
        wrong = self.root / 'profiles/default'
        wrong.mkdir()
        result = self.run_flow('request', '--cli', self.cli, '--connection-directory', wrong)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'calls.jsonl').exists())

    def test_concurrent_stage_cannot_dispatch(self):
        self.request()
        before = (self.root / 'calls.jsonl').read_bytes()
        with (self.out / '.flow.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertNotEqual(self.run_flow('run').returncode, 0)
        self.assertEqual((self.root / 'calls.jsonl').read_bytes(), before)

    def test_active_generation_is_used_without_legacy_agent_path(self):
        generation = 'a' * 32
        agent = self.connection / 'connections' / generation / 'agent/agent-connection.json'
        agent.parent.mkdir(parents=True)
        (self.connection / 'agent-connection.json').rename(agent)
        (self.connection / 'active.json').write_text(json.dumps({'version': 1, 'generation': generation}))
        self.request()
        state = json.loads((self.out / 'qa.json').read_text())
        self.assertEqual(state['agentConnectionFile'], str(agent))


if __name__ == '__main__':
    unittest.main()
