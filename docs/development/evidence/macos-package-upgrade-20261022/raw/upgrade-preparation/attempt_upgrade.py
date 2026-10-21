import hashlib
import json
import os
from pathlib import Path
import runpy
import socket
import subprocess

root = Path('/Users/jiangxinyi/Documents/Project/agent-info')
output = root / 'build/macos-adaptation/issue50-package-11'
evidence = output / 'upgrade-preparation'
stable = root / 'local/中文 Mac 预览/AgentInfoManage'
candidate = output / 'verify/中文 空格 路径/AgentInfoManage'
previous = output / 'previous-installation'
inventory = runpy.run_path(str(root / 'scripts/package-macos.py'))['inventory']
old_manifest = json.loads((stable / 'manifest.json').read_text())
new_manifest = json.loads((candidate / 'manifest.json').read_text())
assert old_manifest['sourceCommit'] == '4690e79357bb728da22193d8dadd6dc8a8ce2ce6'
assert new_manifest['sourceCommit'] == '7edb11c998a1e79e0e92c745b3d0c26d5086e3dd'
old_rows = {row['path']: row for row in old_manifest['files']}
actual_rows = {row['path']: row for row in inventory(stable)}
assert all(actual_rows.get(name) == row for name, row in old_rows.items())
old_additional = sorted(actual_rows.keys() - old_rows.keys())
assert old_additional in [[], ['.local/state/gh/device-id']]
assert inventory(candidate) == new_manifest['files']
assert not previous.exists()
with socket.socket() as probe:
    assert probe.connect_ex(('127.0.0.1', 47125)) != 0
profile = Path.home() / 'Library/Containers/com.example.infoDesktop/Data/Library/Application Support/AgentInfoManage'
before = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
          for p in profile.iterdir() if p.is_file()}
(evidence / 'closed-profile-before.json').write_text(json.dumps(before, indent=2) + '\n')
(evidence / 'old-installed-manifest.json').write_bytes((stable / 'manifest.json').read_bytes())
stable.rename(previous)
try:
    candidate.rename(stable)
except BaseException:
    previous.rename(stable)
    raise
assert inventory(stable) == new_manifest['files']
environment = {'HOME': str(Path.home()), 'USER': 'jiangxinyi', 'LOGNAME': 'jiangxinyi',
               'LANG': 'zh_CN.UTF-8', 'PATH': '/usr/bin:/bin'}
with (evidence / 'new-installed-main.log').open('wb') as log:
    process = subprocess.Popen([str(stable / 'app/info_desktop.app/Contents/MacOS/info_desktop')],
                               cwd='/', env=environment, stdout=log, stderr=subprocess.STDOUT)
    result = {'pid': process.pid, 'oldSource': old_manifest['sourceCommit'],
              'newSource': new_manifest['sourceCommit'], 'payloadEntries': len(new_manifest['files']),
              'wholeDirectoryReplaced': True, 'oldAdditionalRuntimeFiles': old_additional,
              'profileFilesBefore': before,
              'environmentKeys': sorted(environment), 'automaticKeychainRequest': False}
    (evidence / 'upgrade-launch.json').write_text(json.dumps(result, indent=2) + '\n')
    print('UPGRADED_MAIN_PID', process.pid, flush=True)
    code = process.wait()
    with socket.socket() as probe:
        endpoint_closed = probe.connect_ex(('127.0.0.1', 47125)) != 0
    result.update(exit=code, endpointClosed=endpoint_closed)
    (evidence / 'upgrade-launch.json').write_text(json.dumps(result, indent=2) + '\n')
    print('UPGRADED_MAIN_EXIT', code, 'endpointClosed', endpoint_closed, flush=True)
