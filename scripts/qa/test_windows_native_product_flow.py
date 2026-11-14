"""Guard checks only. No App, CLI, credential service or setter is started."""
import base64
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location('windows_native_flow',
    Path(__file__).with_name('windows-native-product-flow.py'))
FLOW = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FLOW)


class ProductFlowGuards(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=FLOW.ROOT / 'build')
        self.root = Path(self.temporary.name)
        self.receiver = self.root / '7zG.exe'
        self.receiver.write_bytes(b'synthetic executable bytes; never run')
        self.receiver_digest = FLOW.digest(self.receiver)

    def tearDown(self):
        self.temporary.cleanup()

    def prepared(self):
        with mock.patch.object(FLOW, 'RECEIVER_SHA256', self.receiver_digest):
            return FLOW.prepare(self.root / 'proof', self.receiver)

    def test_prepare_is_new_and_contains_no_password(self):
        state = self.prepared()
        out = self.root / 'proof'
        self.assertFalse(state['runAttempted'])
        self.assertEqual((out / 'native-background-proof.txt').read_bytes(), FLOW.CONTENT)
        self.assertNotIn(FLOW.PASSWORD, (out / 'qa.json').read_text())
        with mock.patch.object(FLOW, 'RECEIVER_SHA256', self.receiver_digest):
            with self.assertRaises(ValueError):
                FLOW.prepare(out, self.receiver)

    def test_unverified_receiver_and_outside_output_are_refused(self):
        with self.assertRaises(ValueError):
            FLOW.prepare(self.root / 'proof', self.receiver)
        with self.assertRaises(ValueError):
            FLOW.prepare(FLOW.ROOT.parent / 'outside-qa', self.receiver)

    def test_run_claim_is_durable_before_dispatch_and_cannot_repeat(self):
        state = self.prepared()
        out = self.root / 'proof'
        FLOW.claim_run(out, state)
        saved = json.loads((out / 'qa.json').read_text())
        self.assertTrue(saved['runAttempted'])
        with self.assertRaises(ValueError):
            FLOW.claim_run(out, saved)
        with self.assertRaises(ValueError):
            FLOW.main(['run', str(out)])

    def test_public_material_and_private_proof_are_discarded(self):
        for output in [FLOW.PASSWORD.encode(), base64.b64encode(FLOW.PASSWORD.encode()),
                       b'{"privateProof":"synthetic"}', b'{"sessionSecret":"synthetic"}',
                       b'x' * (1024 * 1024 + 1)]:
            with self.assertRaises(ValueError):
                FLOW.safe_output(output)
        FLOW.safe_output(b'{"ok":true,"data":{"itemResults":{"b1":"sent"}}}')

    def test_flow_lock_rejects_a_concurrent_owner(self):
        out = self.root / 'lock'
        out.mkdir()
        with FLOW.exclusive(out):
            with self.assertRaises(OSError):
                with FLOW.exclusive(out):
                    self.fail('The second owner acquired the QA lock')

    def test_candidate_requires_exact_commit_bytes_and_compiled_binding(self):
        candidate = self.root / 'AgentInfoManage'
        (candidate / 'app').mkdir(parents=True)
        (candidate / 'cli').mkdir()
        helper = candidate / 'app/info-native-background-broker.exe'
        helper.write_bytes(b'synthetic helper')
        helper_digest = FLOW.digest(helper)
        app = candidate / 'app/info_desktop.exe'
        app.write_bytes(b'synthetic runner with bound digest ' + helper_digest.encode())
        cli = candidate / 'cli/chiyo.exe'
        cli.write_bytes(b'synthetic CLI')
        source = 'a' * 40
        manifest = {'format': 2, 'sourceCommit': source, 'sourceDirty': False,
            'architecture': 'windows-x64', 'cliEntrypoint': 'cli/chiyo.exe',
            'nativeBackgroundFill': {'helperProtocol': 1,
                'helper': 'app/info-native-background-broker.exe', 'sha256': helper_digest},
            'files': [{'path': path.relative_to(candidate).as_posix(), 'bytes': path.stat().st_size,
                       'sha256': FLOW.digest(path)} for path in [app, cli, helper]]}
        FLOW.write(candidate / 'manifest.json', manifest)
        self.assertEqual(FLOW.candidate_files(candidate, source), (app, cli))
        with self.assertRaises(ValueError):
            FLOW.candidate_files(candidate, 'b' * 40)
        helper.write_bytes(b'changed helper')
        with self.assertRaises(ValueError):
            FLOW.candidate_files(candidate, source)


if __name__ == '__main__':
    unittest.main()
