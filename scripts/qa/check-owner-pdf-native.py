#!/usr/bin/env python3
"""Disposable native Flutter PDF check, isolated checkout/container; no OS input."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[2]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output',type=Path)
    args=parser.parse_args()
    out=args.output.resolve();out.relative_to(ROOT/'build/macos-adaptation');out.mkdir(parents=True,exist_ok=False)
    source=out/'source';products=out/'products';run=uuid.uuid4().hex
    identity='com.example.infoDesktop.zhiyuOwnerPdfCheck.'+run
    commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    preview=ROOT/'apps/desktop/build/macos/Build/Products/Debug/info_desktop.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/kernel_blob.bin'
    sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
    report={'sourceCommit':commit,'complete':False,'phases':[],'previewKernelBefore':sha(preview),'identity':identity}
    env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer',FLUTTER_MACOS_ARM64_ONLY='true',PUB_CACHE=str(ROOT/'.cache/pub'))
    def call(name,command,cwd=ROOT,timeout=600):
        print(name+': started',flush=True)
        with (out/(name+'.log')).open('w') as log:
            p=subprocess.run(command,cwd=cwd,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=timeout)
        report['phases'].append({'name':name,'exit':p.returncode})
        print(name+': '+str(p.returncode),flush=True)
        if p.returncode:raise RuntimeError(name+' failed')
    try:
        call('clone',['git','clone','--shared','--no-checkout','--quiet',str(ROOT),str(source)])
        call('sparse',['git','sparse-checkout','set','apps/desktop','packages','scripts','integrations','third_party'],source)
        call('checkout',['git','checkout','--detach',commit],source)
        (source/'.tools').symlink_to(ROOT/'.tools',target_is_directory=True)
        (source/'.cache').mkdir();(source/'.cache/pub').symlink_to(ROOT/'.cache/pub',target_is_directory=True)
        launcher=str(source/'scripts/dev-macos.sh');desktop=source/'apps/desktop'
        for package in ['info_core','info_cli','info_storage']:
            call('pub-'+package,[launcher,'dart','pub','get','--enforce-lockfile'],source/'packages'/package)
        call('pub-desktop',[launcher,'flutter','pub','get','--enforce-lockfile'],desktop)
        config=out/'PdfCheck.xcconfig'
        config.write_text(f'PRODUCT_BUNDLE_IDENTIFIER = {identity}\nAGENT_INFO_INTERFACE_PREVIEW = NO\nCONFIGURATION_BUILD_DIR = {products}\nDWARF_DSYM_FOLDER_PATH = {products}\n')
        env.update(XCODE_XCCONFIG_FILE=str(config),ZHIYU_PROFILE_DRIVER_REPORT=str(out/'driver.json'))
        target='integration_test/owner_pdf_native_test.dart'
        call('configure',[launcher,'flutter','build','macos','--debug','--config-only','--no-pub','--target',target,
             '--dart-define=OWNER_PDF_NATIVE_RUN='+run,'--dart-define=INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE=false'],desktop)
        call('build',['xcodebuild','-workspace','macos/Runner.xcworkspace','-scheme','Runner','-configuration','Debug',
             '-derivedDataPath',str(out/'xcode'),'-destination','generic/platform=macOS','OBJROOT='+str(out/'xcode/Build/Intermediates.noindex'),
             'SYMROOT='+str(products),'ARCHS=arm64','COMPILER_INDEX_STORE_ENABLE=NO','-quiet'],desktop)
        app=products/'info_desktop.app'
        info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
        if info['CFBundleIdentifier']!=identity or info.get('AgentInfoInterfacePreview')=='YES':raise RuntimeError('Unexpected test App identity')
        entitlements=plistlib.loads(subprocess.check_output(['codesign','-d','--entitlements',':-',str(app)],stderr=subprocess.DEVNULL))
        if entitlements.get('com.apple.security.app-sandbox') is not True:raise RuntimeError('Sandbox disabled')
        report['entitlements']=entitlements
        call('signature',['codesign','--verify','--deep','--strict',str(app)])
        call('drive',[launcher,'flutter','drive','--debug','-d','macos','--no-pub','--target',target,
             '--driver','integration_test/profile_driver.dart','--use-application-binary',str(app)],desktop,300)
        data=json.loads((out/'driver.json').read_text())
        if not isinstance(data,dict) or data.get('passed') is not True or data.get('fixtureRemoved') is not True or len(data.get('checks',[]))!=6:
            raise RuntimeError('Missing native PDF evidence/cleanup')
        report['native']=data;report['complete']=True
    finally:
        binary=str(products/'info_desktop.app/Contents/MacOS/info_desktop')
        processes=subprocess.check_output(['ps','-axo','pid=,comm='],text=True)
        live=any(line.strip().split(None,1)[-1]==binary for line in processes.splitlines() if line.strip())
        report['processStillRunning']=live
        if not live:
            for path in [source,products,out/'xcode']:
                if path.exists():shutil.rmtree(path)
        report['temporaryProductsRemoved']=not products.exists()
        report['previewPreserved']=sha(preview)==report['previewKernelBefore']
        (out/'result.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    if live or not report['previewPreserved']:raise RuntimeError('Native lifecycle/preview not preserved')
    print(json.dumps(report,ensure_ascii=False))

if __name__=='__main__':main()
