"""Disposable loopback fixture: synthetic login and distinct sudo passwords."""
import os
from pathlib import Path
import subprocess
root = Path('/output')
assert root.is_dir() and not any(root.iterdir())
for name in ('host', 'client'):
    subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(root/name)], check=True)
Path('/run/sshd').mkdir(exist_ok=True)
(root/'ready').write_text('ready\n')
os.execv('/usr/sbin/sshd', ['/usr/sbin/sshd', '-D', '-e', '-f', '/fixture/sshd_config'])
