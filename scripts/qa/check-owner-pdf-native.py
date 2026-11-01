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
    parser.add_argument('--file-changes',action='store_true',help='Also use production import, replace and retained-version restore')
    parser.add_argument('--file-outputs',action='store_true',help='Also test real sandbox Save As with a synthetic native picker')
    parser.add_argument('--file-opens',action='store_true',help='Also test Owner temporary copies with an injected document receiver and real channel status')
    parser.add_argument('--file-approvals',action='store_true',help='Use production file approval controls and an actual inherited-sandbox AOT CLI helper')
    parser.add_argument('--file-roundtrip',action='store_true',help='Four launches: file/CLI approval, independent reopen, full restore, restored reopen')
    args=parser.parse_args()
    if args.file_roundtrip and any([args.file_changes,args.file_outputs,args.file_opens,args.file_approvals]):
        parser.error('--file-roundtrip is a separate four-launch scenario')
    out=args.output.resolve();out.relative_to(ROOT/'build/macos-adaptation');out.mkdir(parents=True,exist_ok=False)
    source=out/'source';products=out/'products';run=uuid.uuid4().hex
    identity=('com.example.infoDesktop.zhiyuFileRoundTrip.' if args.file_roundtrip else 'com.example.infoDesktop.zhiyuOwnerPdfCheck.')+run
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
        target='integration_test/owner_file_roundtrip_native_test.dart' if args.file_roundtrip else 'integration_test/owner_pdf_native_test.dart'
        call('configure',[launcher,'flutter','build','macos','--debug','--config-only','--no-pub','--target',target,
             '--dart-define=OWNER_PDF_NATIVE_RUN='+run,'--dart-define=OWNER_FILE_ROUNDTRIP_RUN='+run,'--dart-define=OWNER_FILE_OUTPUTS='+str(args.file_outputs).lower(),'--dart-define=OWNER_FILE_OPENS='+str(args.file_opens).lower(),'--dart-define=OWNER_FILE_APPROVALS='+str(args.file_approvals).lower(),'--dart-define=OWNER_PDF_FILE_CHANGES='+str(args.file_changes).lower(),'--dart-define=INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE=false'],desktop)
        call('build',['xcodebuild','-workspace','macos/Runner.xcworkspace','-scheme','Runner','-configuration','Debug',
             '-derivedDataPath',str(out/'xcode'),'-destination','generic/platform=macOS','OBJROOT='+str(out/'xcode/Build/Intermediates.noindex'),
             'SYMROOT='+str(products),'ARCHS=arm64','COMPILER_INDEX_STORE_ENABLE=NO','-quiet'],desktop)
        app=products/'info_desktop.app'
        if args.file_approvals or args.file_roundtrip:
            helper=app/'Contents/MacOS/info-m07-check'
            call('compile-info',[launcher,'dart','compile','exe','--target-os','macos','--target-arch','arm64','bin/info.dart','-o',str(helper)],source/'packages/info_cli')
            call('sign-info',['codesign','--force','--sign','-','--entitlements',str(desktop/'macos/Runner/Worker.entitlements'),str(helper)])
            call('resign-app',['codesign','--force','--sign','-','--preserve-metadata=entitlements,flags',str(app)])
        info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
        if info['CFBundleIdentifier']!=identity or info.get('AgentInfoInterfacePreview')=='YES':raise RuntimeError('Unexpected test App identity')
        entitlements=plistlib.loads(subprocess.check_output(['codesign','-d','--entitlements',':-',str(app)],stderr=subprocess.DEVNULL))
        if entitlements.get('com.apple.security.app-sandbox') is not True:raise RuntimeError('Sandbox disabled')
        report['entitlements']=entitlements
        call('signature',['codesign','--verify','--deep','--strict',str(app)])
        binary_hash=sha(app/'Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/kernel_blob.bin')
        launches=[]
        for phase in (['live','reopen','restore','restored-read'] if args.file_roundtrip else ['single']):
            driver=out/('driver-'+phase+'.json')
            env['ZHIYU_PROFILE_DRIVER_REPORT']=str(driver)
            call('drive-'+phase,[launcher,'flutter','drive','--debug','-d','macos','--no-pub','--target',target,
                 '--driver','integration_test/profile_driver.dart','--use-application-binary',str(app)],desktop,300)
            data=json.loads(driver.read_text())
            expected={'live':8,'reopen':4,'restore':5,'restored-read':4}[phase] if args.file_roundtrip else ((9 if args.file_changes else 6)+(2 if args.file_outputs else 0)+(3 if args.file_opens else 0)+(7 if args.file_approvals else 0))
            if (not isinstance(data,dict) or data.get('passed') is not True
                    or data.get('runtime',{}).get('platform')!='macos'
                    or data.get('fixtureRemoved') is not (phase=='restored-read' or not args.file_roundtrip)
                    or len(data.get('checks',[]))!=expected):
                raise RuntimeError('Missing native phase evidence/cleanup: '+phase)
            if args.file_roundtrip and data.get('phase')!=phase:
                raise RuntimeError('Unexpected native phase')
            if sha(app/'Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/kernel_blob.bin')!=binary_hash:
                raise RuntimeError('Native App changed across launches')
            launches.append(data)
        if args.file_roundtrip:
            if len({row['pid'] for row in launches})!=4 or len({row['fixtureDirectory'] for row in launches})!=1:
                raise RuntimeError('Expected four distinct native App processes sharing one fixture')
            report['native']={'passed':True,'launches':launches,'nativeKernelSha256':binary_hash}
        else:
            report['native']=launches[0]
        report['complete']=True

    finally:
        binary=str(products/'info_desktop.app/Contents/MacOS/info_desktop')
        processes=subprocess.check_output(['ps','-axo','pid=,comm='],text=True)
        live=any(line.strip().split(None,1)[-1]==binary for line in processes.splitlines() if line.strip())
        report['processStillRunning']=live
        if not live:
            if args.file_roundtrip:
                for evidence in out.glob('driver-*.json'):
                    data=json.loads(evidence.read_text())
                    folder=data.get('fixtureDirectory') if isinstance(data,dict) else None
                    if not folder:continue
                    fixture=Path(folder)
                    allowed=Path.home()/'Library/Containers'/identity/'Data'
                    if fixture.exists():
                        if (fixture.is_symlink() or not fixture.resolve().is_relative_to(allowed.resolve())
                                or fixture.name!='owner-file-roundtrip-'+run
                                or (fixture/'fixture-marker').read_text()!=run):
                            raise RuntimeError('Refuse unknown round-trip fixture')
                        shutil.rmtree(fixture)
            for path in [source,products,out/'xcode']:
                if path.exists():shutil.rmtree(path)
        report['temporaryProductsRemoved']=not products.exists()
        report['previewPreserved']=sha(preview)==report['previewKernelBefore']
        (out/'result.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    if live or not report['previewPreserved']:raise RuntimeError('Native lifecycle/preview not preserved')
    print(json.dumps(report,ensure_ascii=False))

if __name__=='__main__':main()
