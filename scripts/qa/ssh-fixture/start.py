"""Synthetic SSH receiver fixture. All keys are created for this run only."""
import os
from pathlib import Path
import subprocess

root = Path('/output')
assert root.is_dir() and not any(root.iterdir())
for name in ('host', 'client', 'wrong-client'):
    subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(root/name)], check=True)
Path('/run/sshd').mkdir(exist_ok=True)
(root/'ready').write_text('synthetic fixture ready\n')
os.execv('/usr/sbin/sshd', ['/usr/sbin/sshd', '-D', '-e', '-f', '/fixture/sshd_config'])
