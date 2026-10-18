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
import argparse

BASE=Path(__file__).resolve().parent
REPO=BASE.parents[2]
IMAGE='agent-info-manage-ssh-fixture:20261017'
LABEL='agent-info-manage-d7-ssh-native'

def docker(*args):
    p=subprocess.run(['wsl.exe','-d','Ubuntu-24.04','--','docker',*args],capture_output=True,text=True,timeout=40)
    if p.returncode:raise RuntimeError(p.stderr)
    return p.stdout.strip()

def main():
    parser=argparse.ArgumentParser();mode=parser.add_mutually_exclusive_group();mode.add_argument('--native',action='store_true');mode.add_argument('--suite',action='store_true');mode.add_argument('--checks',action='store_true');parser.add_argument('--repeat',type=int,default=1);parser.add_argument('--cli-executable',type=Path);args=parser.parse_args()
    assert 1<=args.repeat<=3
    cli=(args.cli_executable or REPO/'.scratch/d7-aot/info.exe').resolve()
    runs=REPO/'.scratch/ssh-native-runs'
    runs.mkdir(parents=True,exist_ok=True)
    root=Path(tempfile.mkdtemp(prefix='synthetic-',dir=runs)).resolve()
    assert root.parent==runs.resolve()
    output=root/'keys';output.mkdir()
    linux='/mnt/'+str(output)[0].lower()+str(output)[2:].replace('\\','/')
    container=None
    keepalive=subprocess.Popen(['wsl.exe','-d','Ubuntu-24.04','--','sh','-c','read -r fixture_done'],stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
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
        material_temp=root/('materials' if args.suite or args.checks else '材料 空格');material_temp.mkdir()
        env.update({'D7_SSH_FIXTURE':str(output),'D7_SSH_PORT':binding.split(':')[-1],
          'TEMP':str(material_temp),'TMP':str(material_temp),
          'D7_SSH_EXE':str(Path(os.environ['SystemRoot'])/'System32/OpenSSH/ssh.exe')})
        dart=Path.home()/'.local/share/flutter/bin/cache/dart-sdk/bin/dart.exe'
        if args.native:
            flutter=Path.home()/'.local/share/flutter/bin/flutter.bat'
            command=[str(flutter),'test','--no-pub','integration_test/file_runtime_native_test.dart','-d','windows',
              '--dart-define=CLI_EXECUTABLE='+str(cli),
              '--dart-define=SSH_EXECUTABLE='+env['D7_SSH_EXE'],'--dart-define=SSH_FIXTURE='+str(output),'--dart-define=SSH_FIXTURE_PORT='+env['D7_SSH_PORT']]
            cwd=REPO/'apps/desktop'
        elif args.checks:
            command=['pwsh.exe','-NoProfile','-File',str(REPO/'scripts/check.ps1'),'-FlutterBin',str(Path.home()/'.local/share/flutter/bin'),'-Offline'];cwd=REPO
        else:
            command=[str(dart),'test',*([] if args.suite else ['test/ssh_receiver_native_test.dart'])];cwd=REPO/'packages/info_cli'
        if args.suite or args.checks:
            env['D6_COMPILED_CLI']=str(cli)
            assert Path(env['D6_COMPILED_CLI']).is_file()
            assert Path(env['D7_AWS_EXE']).is_file()
        for _ in range(args.repeat):
            p=subprocess.run(command,cwd=cwd,env=env,timeout=240 if args.native else 180 if args.checks else 100)
            if p.returncode:break
    finally:
        try:
            if container:
                assert docker('inspect',container,'--format','{{index .Config.Labels "task"}}')==LABEL
                docker('stop','-t','1',container)
        finally:
            keepalive.stdin.close();keepalive.wait(timeout=10)
    print(json.dumps({'imageId':image,'testExitCode':p.returncode,'fixture':'synthetic localhost only','containerRemovedAfterRun':True}))
    return p.returncode

if __name__=='__main__':raise SystemExit(main())
