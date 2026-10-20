"""Observe abrupt death of one explicitly isolated GUI, never a user profile."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import uuid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--worker', type=Path, required=True)
    args = parser.parse_args()
    app, worker = args.app.resolve(), args.worker.resolve()
    assert app.is_file() and worker.is_file()
    repo = Path(__file__).resolve().parents[2]
    base = repo / '.scratch/native-hosted-crash'
    base.mkdir(parents=True, exist_ok=True)
    root = base / ('synthetic-' + uuid.uuid4().hex)
    root.mkdir()
    assert root.resolve() == root and root.parent == base.resolve()
    config = root / 'configuration.json'
    config.write_text(json.dumps({
        'worker': str(worker), 'keys': os.environ['D7_SSH_FIXTURE'],
        'port': os.environ['D7_SSH_PORT'], 'ssh': os.environ['D7_SSH_EXE'],
    }), encoding='utf-8')
    processes = []
    try:
        with (root / 'gui-run.log').open('wb') as log:
            first = subprocess.Popen([str(app), str(config), 'run'], stdout=log, stderr=log)
            processes.append(first)
            deadline = time.monotonic() + 30
            while not (root / 'ready.json').exists():
                assert first.poll() is None, 'GUI exited before running SSH'
                assert time.monotonic() < deadline, 'GUI readiness deadline'
                time.sleep(.05)
            (root / 'crash-now').write_text('terminate only this synthetic GUI', encoding='utf-8')
            assert first.wait(timeout=10) != 0, 'Abrupt GUI termination expected'
        with (root / 'gui-verify.log').open('wb') as log:
            second = subprocess.Popen([str(app), str(config), 'verify'], stdout=log, stderr=log)
            processes.append(second)
            code = second.wait(timeout=40)
        if code:
            failure = root / 'failure.json'
            if failure.exists():
                print('GUI_CRASH_FAILURE ' + failure.read_text(encoding='utf-8'))
        assert code == 0, 'GUI restart verifier failed'
        result = json.loads((root / 'result.json').read_text(encoding='utf-8'))
        assert len(result) == 7 and all(value is True for value in result.values())
        print('WINDOWS_HOSTED_CRASH_VERIFIED ' + json.dumps(result, sort_keys=True))
        # The synthetic private session/profile and VM logs remain ignored QA
        # material. Do not export these files with the safe boolean evidence.
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)


if __name__ == '__main__':
    main()
