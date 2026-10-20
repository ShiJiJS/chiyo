"""Run the isolated Mac workflow acceptance with a fresh loopback SSH fixture.

Use the project QA venv (paramiko==5.1.0). The default run uses an ordinary
application binding and needs Computer Use for approval/history. Its synthetic
file can also be replaced/exported through the real panels. --automatic uses a
widget-test binding and stubs only picker paths.
"""
import argparse
import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--automatic', action='store_true',
                      help='Use fixture paths instead of OS panels; not panel acceptance')
    mode.add_argument('--live', action='store_true',
                      help='Default: ordinary app binding; real UI and seeded synthetic file')
    args = parser.parse_args()
    live = not args.automatic
    if sys.platform != 'darwin':
        parser.error('This acceptance requires macOS')
    repo = Path(__file__).resolve().parents[2]
    base = repo / 'build' / 'macos-adaptation'
    base.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix='native-run-', dir=base)).resolve()
    root.chmod(0o700)
    with (root / 'ssh.log').open('wb') as log:
        server = subprocess.Popen([sys.executable, str(repo / 'scripts/qa/macos-ssh-fixture.py'),
                                   str(root / 'ssh')], stdout=log, stderr=log)
        try:
            facts_file = root / 'ssh' / 'fixture.json'
            deadline = time.monotonic() + 30
            while not facts_file.exists():
                if server.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError(f'SSH fixture unavailable; inspect {root / "ssh.log"}')
                time.sleep(0.05)
            facts = json.loads(facts_file.read_text())
            keys = root / 'ssh'
            defines = root / 'defines.json'
            defines.write_text(json.dumps({
                'SYNTHETIC_SSH_KEY': base64.b64encode((keys / 'client').read_bytes()).decode(),
                'SYNTHETIC_SSH_HOST': ' '.join((keys / 'host.pub').read_text().split()[:2]),
                'SYNTHETIC_SSH_PORT': str(facts['port']),
                'MAC_QA_AUTOMATIC': args.automatic,
            }))
            defines.chmod(0o600)
            print(f'Isolated Mac QA materials: {root}', flush=True)
            print('Ordinary app binding; seeded file, actual approval/history UI.' if live else
                  'Picker fixtures only; native panels remain unverified.',
                  flush=True)
            command = [str(repo / 'scripts/dev-macos.sh'), 'flutter']
            command += (['run', '--no-pub', '-t', 'integration_test/macos_workflows_manual.dart']
                        if live else
                        ['test', '--no-pub', 'integration_test/macos_workflows_native_test.dart'])
            command += ['-d', 'macos', f'--dart-define-from-file={defines}']
            result = subprocess.run(command, cwd=repo / 'apps/desktop', timeout=30 * 60 if live else 15 * 60)
            return result.returncode
        finally:
            if server.poll() is None:
                server.terminate()
            server.wait(timeout=15)


if __name__ == '__main__':
    raise SystemExit(main())
