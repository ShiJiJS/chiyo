import json
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
manifest = json.loads((stable / 'manifest.json').read_text())
assert manifest['sourceCommit'] == '7edb11c998a1e79e0e92c745b3d0c26d5086e3dd'
assert inventory(stable) == manifest['files']
assert not candidate.exists()
with socket.socket() as probe:
    assert probe.connect_ex(('127.0.0.1', 47125)) != 0
stable.rename(candidate)
previous.rename(stable)
old_manifest = json.loads((stable / 'manifest.json').read_text())
assert old_manifest['sourceCommit'] == '4690e79357bb728da22193d8dadd6dc8a8ce2ce6'
actual = {row['path']: row for row in inventory(stable)}
assert all(actual.get(row['path']) == row for row in old_manifest['files'])
environment = {'HOME': str(Path.home()), 'USER': 'jiangxinyi', 'LOGNAME': 'jiangxinyi',
               'LANG': 'zh_CN.UTF-8', 'PATH': '/usr/bin:/bin'}
with (evidence / 'restored-old-main.log').open('wb') as log:
    process = subprocess.Popen([str(stable / 'app/info_desktop.app/Contents/MacOS/info_desktop')],
                               cwd='/', env=environment, stdout=log, stderr=subprocess.STDOUT)
    result = {'pid':process.pid, 'restoredSource':old_manifest['sourceCommit'],
              'allManifestEntriesUnchanged':True, 'wholeDirectoryRestored':True,
              'keychainOrDatabaseReplaced':False}
    (evidence / 'restored-old-launch.json').write_text(json.dumps(result,indent=2)+'\n')
    print('RESTORED_MAIN_PID',process.pid,flush=True)
    code=process.wait()
    result['exit']=code
    (evidence / 'restored-old-launch.json').write_text(json.dumps(result,indent=2)+'\n')
    print('RESTORED_MAIN_EXIT',code,flush=True)
