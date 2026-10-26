#!/usr/bin/env python3
"""Run two self-contained Cocoa lifecycle checks on the isolated preview."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    app = args.app.resolve()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if (info.get('CFBundleIdentifier') != 'com.example.infoDesktop.zhiyuPreview'
            or info.get('AgentInfoInterfacePreview') != 'YES'
            or Path(info.get('AgentInfoFlutterTarget', '')).name != 'zhiyu_preview_lifecycle.dart'):
        raise ValueError('Only the isolated lifecycle QA entry point may run')
    worker = app / 'Contents/MacOS/info-runtime-worker'
    if worker.exists():
        raise ValueError('An isolated preview must not contain an execution worker')
    binary = app / 'Contents/MacOS' / info['CFBundleExecutable']
    args.output.mkdir(parents=True, exist_ok=False)
    facts = {'applicationId': info['CFBundleIdentifier'], 'workerPresent': False,
             'binarySha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
             'scope': 'Cocoa self-menu quit and window performClose; no OS key synthesis',
             'runs': [], 'complete': False}
    report = args.output / 'result.json'

    def save():
        report.write_text(json.dumps(facts, ensure_ascii=False, indent=2) + '\n')

    save()
    for action in ['quit', 'close']:
        env = {key: os.environ[key] for key in ['HOME', 'USER', 'LOGNAME', 'LANG'] if key in os.environ}
        env.update(PATH='/usr/bin:/bin', ZHIYU_PREVIEW_SMOKE_ACTION=action)
        with (args.output / (action + '.txt')).open('w') as log:
            child = subprocess.Popen([str(binary)], cwd='/', env=env, stdout=log,
                                     stderr=subprocess.STDOUT, text=True)
            run = {'action': action, 'pid': child.pid}
            facts['runs'].append(run)
            save()
            try:
                run['exitCode'] = child.wait(timeout=30)
            except subprocess.TimeoutExpired:
                run['normalExit'] = False
                # Cleanup of this exact self-created QA process is recorded as
                # a failure, never counted as normal application termination.
                child.terminate()
                run['cleanupExitCode'] = child.wait(timeout=10)
                save()
                raise RuntimeError(action + ' did not terminate normally')
        text = (args.output / (action + '.txt')).read_text()
        markers = re.findall(r'^(?:flutter: )?ZHIYU_LIFECYCLE=(.+)$', text, re.M)
        if len(markers) != 1:
            save()
            raise RuntimeError(action + ' did not render and report its native state')
        run['state'] = json.loads(markers[0])
        native = run['state']['native']
        run['normalExit'] = (run['exitCode'] == 0 and run['state']['action'] == action
                             and native.get('isolated') is True
                             and native.get('productionServices') is False
                             and native.get('savedDirectories') is False
                             and native.get('title') == '知予 · 界面预览·示例数据'
                             and run['state']['renderedFramesSettled'] is True)
        save()
        if not run['normalExit']:
            raise RuntimeError(action + ' lifecycle check failed')
    facts['complete'] = True
    save()
    print(json.dumps(facts, ensure_ascii=False))


if __name__ == '__main__':
    main()
