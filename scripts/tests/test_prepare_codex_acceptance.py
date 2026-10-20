"""Configuration-boundary tests; fixtures do not represent native client runs."""
import base64
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'prepare-codex-acceptance.py'
spec = importlib.util.spec_from_file_location('prepare_codex_acceptance', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='aim-prepare-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def fixture(self, architecture):
        suffix = '.exe' if architecture == 'windows-x64' else ''
        delivery = self.root / 'delivery'
        bundle = self.root / "中文 space 'quote $literal; bundle"
        delivery.mkdir()
        bundle.mkdir()
        files = []
        for name in ['info-codex', 'info-codex-hook', 'info-runtime-worker']:
            path = delivery / 'cli' / (name + suffix)
            path.parent.mkdir(exist_ok=True)
            path.write_bytes(b'synthetic configuration fixture: ' + name.encode())
            (bundle / (name + suffix)).write_bytes(path.read_bytes())
        template = delivery / 'cli/template'
        (template / 'references').mkdir(parents=True)
        (template / 'SKILL.md').write_text('Synthetic skill\n')
        for name in ['credential-use.md', 'information-files.md']:
            (template / 'references' / name).write_text(name)
        skill = bundle / 'skills/agent-info-access'
        (skill / 'references').mkdir(parents=True)
        (skill / 'SKILL.md').write_text(
            f'Synthetic skill\n\nBundle executable: `{bundle.as_posix()}/info-codex{suffix}`.\n')
        for name in ['credential-use.md', 'information-files.md']:
            (skill / 'references' / name).write_bytes((template / 'references' / name).read_bytes())
        for path in sorted(delivery.rglob('*')):
            if path.is_file():
                data = path.read_bytes()
                files.append(dict(path=path.relative_to(delivery).as_posix(), bytes=len(data),
                                  sha256=hashlib.sha256(data).hexdigest()))
        (delivery / 'manifest.json').write_text(json.dumps(dict(
            architecture=architecture, release='synthetic', sourceCommit='fixture', files=files)))
        hook_path = f'{bundle.as_posix()}/info-codex-hook{suffix}'
        posix = "'" + hook_path.replace("'", "'\"'\"'") + "'"
        windows = "& '" + hook_path.replace("'", "''") + "'"
        hooks = {}
        for event, timeout in [('SessionStart', 15), ('SubagentStart', 5), ('SessionEnd', 3)]:
            handler = dict(type='command', command=posix, timeout=timeout, additionalContextLimit=0,
                commandWindows='powershell.exe -NoProfile -NonInteractive -EncodedCommand ' +
                base64.b64encode(windows.encode('utf-16-le')).decode())
            group = dict(hooks=[handler])
            if event == 'SessionStart':
                group['matcher'] = '^(startup|resume|clear|compact|fork)$'
            hooks[event] = [group]
        (bundle / 'hooks.json').write_text(json.dumps(dict(description='fixture', hooks=hooks)))
        return delivery, bundle

    def test_windows_layout_and_literal_path_preserved(self):
        delivery, bundle = self.fixture('windows-x64')
        workspace = self.root / 'workspace'
        result = module.prepare(delivery, bundle, workspace)
        self.assertEqual(result['architecture'], 'windows-x64')
        self.assertIn('app/info_desktop.exe', (workspace / 'README.txt').read_text())
        self.assertFalse(result['trusted'])
        self.assertEqual((workspace / '.codex/hooks.json').read_bytes(), (bundle / 'hooks.json').read_bytes())

    def test_mac_layout_and_cases_are_unexecuted(self):
        delivery, bundle = self.fixture('macos-arm64')
        workspace = self.root / 'workspace'
        result = module.prepare(delivery, bundle, workspace)
        self.assertEqual(result['architecture'], 'macos-arm64')
        self.assertIn('app/info_desktop.app', (workspace / 'README.txt').read_text())
        self.assertEqual(result['casesRun'], 0)
        cases = json.loads((workspace / 'acceptance-cases.json').read_text())
        self.assertEqual(len(cases), 13)
        self.assertTrue(all(c['state'] == 'not_run' for c in cases))

    def test_existing_workspace_is_byte_preserved(self):
        delivery, bundle = self.fixture('macos-arm64')
        workspace = self.root / 'workspace'
        module.prepare(delivery, bundle, workspace)
        before = {p.relative_to(workspace): p.read_bytes() for p in workspace.rglob('*') if p.is_file()}
        with self.assertRaisesRegex(ValueError, 'Workspace exists'):
            module.prepare(delivery, bundle, workspace)
        self.assertEqual(before, {p.relative_to(workspace): p.read_bytes() for p in workspace.rglob('*') if p.is_file()})

    def test_hook_mutations_refused_before_writes(self):
        delivery, bundle = self.fixture('macos-arm64')
        hook_file = bundle / 'hooks.json'
        original = json.loads(hook_file.read_text())
        for mutation in ['posix-target', 'windows-target', 'matcher', 'async', 'duplicate', 'stop-event']:
            with self.subTest(mutation=mutation):
                config = copy.deepcopy(original)
                group = config['hooks']['SessionStart'][0]
                handler = group['hooks'][0]
                if mutation == 'posix-target': handler['command'] += ' ; echo unexpected'
                elif mutation == 'windows-target': handler['commandWindows'] += ' extra'
                elif mutation == 'matcher': group['matcher'] = '.*'
                elif mutation == 'async': handler['async'] = True
                elif mutation == 'duplicate': group['hooks'].append(copy.deepcopy(handler))
                else: config['hooks']['Stop'] = copy.deepcopy(config['hooks']['SessionEnd'])
                hook_file.write_text(json.dumps(config))
                destination = self.root / mutation
                expected_error = {'posix-target': 'POSIX hook target', 'windows-target': 'Windows command wrapper',
                    'matcher': 'SessionStart matcher', 'async': 'handler fields',
                    'duplicate': 'hook count', 'stop-event': 'hook events'}[mutation]
                with self.assertRaisesRegex(ValueError, expected_error):
                    module.prepare(delivery, bundle, destination)
                self.assertFalse(destination.exists())

    def test_changed_payload_and_unknown_platform_refused(self):
        delivery, bundle = self.fixture('macos-arm64')
        binary = bundle / 'info-codex'
        original = binary.read_bytes()
        binary.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'binary differs'):
            module.prepare(delivery, bundle, self.root / 'changed')
        binary.write_bytes(original)
        manifest_path = delivery / 'manifest.json'
        manifest = json.loads(manifest_path.read_text())
        manifest['architecture'] = 'unrecognized'
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, 'Unsupported delivery'):
            module.prepare(delivery, bundle, self.root / 'unknown')
        self.assertFalse((self.root / 'changed').exists())
        self.assertFalse((self.root / 'unknown').exists())


if __name__ == '__main__':
    unittest.main()
