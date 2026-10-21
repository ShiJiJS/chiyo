#!/usr/bin/env python3
"""Keep an isolated signed Release Flutter service live for real Codex tests.

Only synthetic data and a QA-only owner file controller. No Keychain, hooks,
trust changes, Codex threads or models are started by this runner.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import time
import uuid

ROOT=Path(__file__).resolve().parents[2]
ENTRY='apps/desktop/integration_test/macos_codex_live.dart'

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('output',type=Path);args=parser.parse_args()
    out=args.output.resolve();out.relative_to(ROOT/'build/macos-adaptation');out.mkdir(parents=True,exist_ok=False)
    with socket.socket() as s:
        s.settimeout(1)
        assert s.connect_ex(('127.0.0.1',47125))!=0,'Existing service: do not replace or stop it'
    source=out/'source';source.mkdir();logs=out/'logs';logs.mkdir()
    owner=uuid.uuid4().hex;state={'complete':False,'commands':[],'scope':__doc__}
    state['sourceCommit']=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    def save(): (out/'result.json').write_text(json.dumps(state,indent=2)+'\n')
    def run(label,cmd,cwd=source):
        with (logs/(label+'.txt')).open('wb') as f:r=subprocess.run(cmd,cwd=cwd,stdout=f,stderr=subprocess.STDOUT,timeout=900)
        state['commands'].append({'label':label,'command':cmd,'exitCode':r.returncode});save();print(label,r.returncode,flush=True);assert r.returncode==0,label
    names=subprocess.check_output(['git','ls-files','-z','apps/desktop','packages','scripts','integrations','third_party'],cwd=ROOT).decode().split('\0')
    hashes={}
    for name in sorted(set(filter(None,names))|{ENTRY,'scripts/qa/macos-codex-live.py'}):
        p=ROOT/name
        assert p.is_file() and not p.is_symlink(),name
        dest=source/name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,dest)
        hashes[name]=hashlib.sha256(p.read_bytes()).hexdigest()
    state['inputSourceHashes']=hashes
    (source/'.tools').symlink_to(ROOT/'.tools',target_is_directory=True)
    (source/'.cache').mkdir();(source/'.cache/pub').symlink_to(ROOT/'.cache/pub',target_is_directory=True)
    config=source/'apps/desktop/macos/Runner/Configs/AppInfo.xcconfig';text=config.read_text();anchor='PRODUCT_BUNDLE_IDENTIFIER = com.example.infoDesktop';assert text.count(anchor)==1
    identity='org.shijijs.agent-info-manage.qa.codex.'+owner;config.write_text(text.replace(anchor,'PRODUCT_BUNDLE_IDENTIFIER = '+identity));state['bundleIdentifier']=identity
    state['copyModifications']={str(config.relative_to(source)):hashlib.sha256(config.read_bytes()).hexdigest()}
    for name,digest in hashes.items():
        if name not in state['copyModifications']:assert hashlib.sha256((source/name).read_bytes()).hexdigest()==digest
    save();launcher=str(source/'scripts/dev-macos.sh')
    for package in ['info_core','info_cli','info_storage']:
        run('pub-'+package,[launcher,'dart','pub','get','--enforce-lockfile'],source/'packages'/package)
    desktop=source/'apps/desktop';run('pub-desktop',[launcher,'flutter','pub','get','--enforce-lockfile'],desktop)
    run('analyze',[launcher,'flutter','analyze','--no-pub','--fatal-infos','--fatal-warnings'],desktop)
    run('build-release',[launcher,'build','--target=integration_test/macos_codex_live.dart'])
    app=desktop/'build/macos/Build/Products/Release/info_desktop.app';binary=app/'Contents/MacOS/info_desktop'
    run('signature',['/usr/bin/codesign','--verify','--deep','--strict',str(app)])
    run('entitlements',['/usr/bin/codesign','-d','--entitlements',':-',str(app)])
    state['binarySha256']=hashlib.sha256(binary.read_bytes()).hexdigest()
    environment=os.environ.copy();environment['MAC_QA_OWNER']=owner
    with (logs/'app.txt').open('wb') as f:process=subprocess.Popen([str(binary)],cwd=source,env=environment,stdout=f,stderr=subprocess.STDOUT)
    state['pid']=process.pid;state['running']=True;save();directory=None
    deadline=time.monotonic()+60
    while time.monotonic()<deadline:
        lines=(logs/'app.txt').read_text(errors='replace');matches=re.findall(r'MAC_CODEX_LIVE_ROOT=([^\r\n]+)',lines)
        if matches:
            p=Path(matches[-1]);assert p.is_absolute() and p.name.startswith('aim-mac-codex-live-') and not p.is_symlink()
            assert (p/'.qa-owner').read_text()==owner;directory=p.resolve()
            if (directory/'ready.json').exists():break
        assert process.poll() is None,'QA application exited before ready';time.sleep(.05)
    assert directory and (directory/'ready.json').exists(),'QA application startup deadline'
    controller=out/'controller.json';fd=os.open(controller,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'w') as f:json.dump({'owner':owner,'root':str(directory),'pid':process.pid,'app':str(app)},f)
    state['ready']=json.loads((directory/'ready.json').read_text());state['controllerReady']=True;save()
    print('MAC_CODEX_SERVICE_READY='+str(directory),flush=True)
    def request_quit(_signal=None,_frame=None):
        indices=[int(p.stem.split('-')[1]) for p in directory.glob('command-*.json')]
        target=directory/f'command-{max(indices,default=0)+1}.json'
        if not target.exists():target.write_text(json.dumps({'owner':owner,'action':'quit'}))
    signal.signal(signal.SIGTERM,request_quit)
    signal.signal(signal.SIGINT,request_quit)
    try:
        while process.poll() is None:time.sleep(.2)
        state['exitCode']=process.returncode;state['running']=False
        replies=sorted(directory.glob('reply-*.json'),key=lambda p:int(p.stem.split('-')[1]))
        if replies:state['lastOwnerReply']=json.loads(replies[-1].read_text())
        state['complete']=process.returncode==0 and bool(state.get('lastOwnerReply',{}).get('quitting'))
        for p in replies:shutil.copyfile(p,out/p.name)
        if state['complete']:
            assert (directory/'.qa-owner').read_text()==owner and not directory.is_symlink();shutil.rmtree(directory);state['ownedFixtureRemoved']=True
            controller.unlink()
        else:state['retainedOwnedRoot']=str(directory)
    finally:save()
    print(json.dumps({'complete':state['complete'],'exitCode':process.returncode}),flush=True)
    if not state['complete']:raise SystemExit(1)

if __name__=='__main__':main()
