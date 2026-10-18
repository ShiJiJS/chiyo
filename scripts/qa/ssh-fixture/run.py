"""Run product credential flow against a disposable localhost SSH receiver.

Build the adjacent Dockerfile as agent-info-manage-ssh-fixture:20261017 in
WSL Ubuntu-24.04 first. All keys are generated here; no personal profile is read.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

BASE=Path(__file__).resolve().parent
REPO=BASE.parents[2]
IMAGE='agent-info-manage-ssh-fixture:20261017'
LABEL='agent-info-manage-d7-ssh-native'

def docker(*args):
    p=subprocess.run(['wsl.exe','-d','Ubuntu-24.04','--','docker',*args],capture_output=True,text=True,timeout=40)
    if p.returncode:raise RuntimeError(p.stderr)
    return p.stdout.strip()

def main():
    runs=REPO/'.scratch/ssh-native-runs'
    runs.mkdir(parents=True,exist_ok=True)
    root=Path(tempfile.mkdtemp(prefix='synthetic-',dir=runs)).resolve()
    assert root.parent==runs.resolve()
    output=root/'keys';output.mkdir()
    linux='/mnt/'+str(output)[0].lower()+str(output)[2:].replace('\\','/')
    container=None
    try:
        image=docker('image','inspect',IMAGE,'--format','{{.Id}}')
        container=docker('run','--rm','-d','--label','task='+LABEL,'-p','127.0.0.1::2222','--mount','type=bind,source='+linux+',target=/output',image)
        for _ in range(150):
            if (output/'ready').exists():break
            time.sleep(.1)
        assert (output/'ready').exists(),'SSH fixture did not become ready'
        binding=docker('port',container,'2222/tcp')
        assert binding.startswith('127.0.0.1:')
        env=os.environ.copy()
        material_temp=root/'材料 空格';material_temp.mkdir()
        env.update({'D7_SSH_FIXTURE':str(output),'D7_SSH_PORT':binding.split(':')[-1],
          'TEMP':str(material_temp),'TMP':str(material_temp),
          'D7_SSH_EXE':str(Path(os.environ['SystemRoot'])/'System32/OpenSSH/ssh.exe')})
        dart=Path.home()/'.local/share/flutter/bin/cache/dart-sdk/bin/dart.exe'
        p=subprocess.run([str(dart),'test','test/ssh_receiver_native_test.dart'],cwd=REPO/'packages/info_cli',env=env,timeout=100)
    finally:
        if container:
            assert docker('inspect',container,'--format','{{index .Config.Labels "task"}}')==LABEL
            docker('stop','-t','1',container)
    print(json.dumps({'imageId':image,'testExitCode':p.returncode,'fixture':'synthetic localhost only','containerRemovedAfterRun':True}))
    return p.returncode

if __name__=='__main__':raise SystemExit(main())
