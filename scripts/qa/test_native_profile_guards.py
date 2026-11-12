"""Guard the developer runner's artifact ownership and result-mode boundary."""
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


runner = module('profile_runner', 'run-zhiyu-profile.py')
collector = module('native_collector', 'collect-zhiyu-native.py')


class ProfileGuards(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='profile-guards-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def test_foreign_identity_is_rejected_before_native_tools(self):
        app = self.root / 'foreign.app'
        (app / 'Contents').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'owners.production.app', 'AgentInfoInterfacePreview': 'YES'}))
        with patch.object(runner.subprocess, 'check_output') as invoked:
            with self.assertRaises(ValueError):
                runner.inspect_app(app)
            invoked.assert_not_called()
        self.assertTrue(app.exists())

    def test_additional_app_is_never_silently_removed(self):
        expected = self.root / 'Debug/info_desktop.app'
        other = self.root / 'other.app'
        expected.mkdir(parents=True)
        other.mkdir()
        with self.assertRaises(ValueError):
            runner.one_app(self.root, expected)
        self.assertTrue(expected.exists())
        self.assertTrue(other.exists())

    def test_existing_output_is_rejected_without_inspecting_or_rebuilding_app(self):
        output = self.root / 'build/zhiyu-ui/existing'
        output.mkdir(parents=True)
        sentinel = output / 'keep.txt'
        sentinel.write_text('keep')
        with patch.object(runner, 'ROOT', self.root), \
                patch.object(runner, 'inspect_app') as inspect:
            with self.assertRaises(ValueError):
                runner.run(output, False, 'python3', 1)
            inspect.assert_not_called()
        self.assertEqual(sentinel.read_text(), 'keep')

    def test_failed_or_unattested_profile_result_never_collects_or_deletes_sources(self):
        log = self.root / 'drive.log'
        log.write_text('All tests passed!\n')
        receipt = self.root / 'profile-result.json'
        good = {'allTestsPassed': True, 'driverExitCode': 0,
                'runtime': {'profileMode': True},
                'profileApp': {'sandboxed': True, 'aotSnapshotSymbolsPresent': True}}
        cases = [{**good, 'allTestsPassed': False}, {**good, 'driverExitCode': 1},
                 {**good, 'runtime': {'profileMode': False}},
                 {**good, 'profileApp': {'sandboxed': False, 'aotSnapshotSymbolsPresent': True}},
                 {**good, 'profileApp': {'sandboxed': True, 'aotSnapshotSymbolsPresent': False}}]
        for data in cases:
            receipt.write_text(json.dumps(data))
            with self.subTest(data=data), patch('sys.argv', [
                    'collect', '--log', str(log), '--profile-result', str(receipt),
                    '--output', str(self.root / 'out'), '--python', 'python3']), \
                    patch.object(collector.shutil, 'copytree') as copied, \
                    patch.object(collector.shutil, 'rmtree') as removed:
                with self.assertRaises(ValueError):
                    collector.main()
                copied.assert_not_called()
                removed.assert_not_called()

    def test_configuration_failure_preserves_initial_app_without_deleting_products(self):
        fake = self.root / 'repo'
        app = fake / 'apps/desktop/build/macos/Build/Products/Debug/info_desktop.app'
        app.mkdir(parents=True)
        sentinel = app / 'keep.bin'
        sentinel.write_bytes(b'initial preview')
        initial = {'kernelPresent': True, 'aotSnapshotSymbolsPresent': False}
        output = fake / 'build/zhiyu-ui/new'
        with patch.object(runner, 'ROOT', fake), \
                patch.object(runner, 'inspect_app', return_value=initial), \
                patch.object(runner, 'run_command', return_value={'exitCode': 1}) as commands, \
                patch.object(runner.shutil, 'rmtree') as removed:
            with self.assertRaises(RuntimeError):
                runner.run(output, False, 'python3', 1)
            self.assertEqual(commands.call_count, 1)
            removed.assert_not_called()
        self.assertEqual(sentinel.read_bytes(), b'initial preview')
        self.assertTrue(json.loads((output / 'result.json').read_text())['initialAppUnchanged'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
