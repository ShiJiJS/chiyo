#!/usr/bin/env python3
"""Build one disposable, isolated native owner UI check; preserve the preview."""
import base64
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import uuid
import time
import re
import socket
import sys

ROOT = Path(__file__).resolve().parents[2]
DESKTOP = ROOT / 'apps/desktop'
TARGET = 'integration_test/owner_workspace_native_test.dart'
IDENTITY = 'com.example.infoDesktop.zhiyuOwnerCheck'


def drive_with_real_client(command, output, env, workflow_run, project, package, scenario="owner-ui"):
    """One owned native test App, with the existing approved synthetic project."""
    controller = output / 'controller.json'
    root = None
    client_code = None
    with (output / 'drive-real-codex.log').open('w') as log:
        drive = subprocess.Popen(command, cwd=DESKTOP, env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                matches = re.findall(r'MAC_CODEX_LIVE_ROOT=([^\r\n]+)', (output / 'drive-real-codex.log').read_text())
                if matches:
                    root = Path(matches[-1])
                    expected = Path.home() / 'Library/Containers' / IDENTITY / 'Data'
                    root.resolve().relative_to(expected.resolve())
                    if root.is_symlink() or root.name != 'owner-workflow-' + workflow_run or (root / '.qa-owner').read_text() != workflow_run:
                        raise RuntimeError('Unexpected native controller fixture')
                    if (root / 'ready.json').is_file():
                        break
                if drive.poll() is not None:
                    raise RuntimeError('Native UI exited before ready')
                time.sleep(.1)
            else:
                raise TimeoutError('Native owner UI startup')
            with controller.open('x') as stream:
                os.chmod(controller, 0o600)
                json.dump({'root': str(root), 'owner': workflow_run}, stream)
            print('real Codex client: started', flush=True)
            with (output / 'real-client.log').open('w') as client_log:
                result = subprocess.run([sys.executable, str(ROOT / 'scripts/qa/macos-codex-client.py'),
                    str(output / 'real-client'), '--case', scenario, '--project', str(project),
                    '--host', str(output), '--package', str(package)], cwd=ROOT, stdout=client_log,
                    stderr=subprocess.STDOUT, timeout=780)
            client_code = result.returncode
            print('real Codex client: exit ' + str(client_code), flush=True)
        finally:
            if root is not None and drive.poll() is None and root.is_dir():
                indices = [int(p.stem.split('-')[1]) for p in root.glob('command-*.json')]
                command_path = root / f'command-{max(indices, default=0)+1}.json'
                temporary = command_path.with_suffix('.partial')
                temporary.write_text(json.dumps({'owner': workflow_run, 'action': 'quit'}))
                temporary.rename(command_path)
            try:
                drive_code = drive.wait(timeout=60)
            except subprocess.TimeoutExpired:
                drive.terminate()
                drive_code = drive.wait(timeout=15)
            controller.unlink(missing_ok=True)
        if client_code != 0 or drive_code != 0:
            raise RuntimeError(f'Real client/native driver failed: {client_code}/{drive_code}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--workflow', action='store_true', help='Full owner workflow in two launches of one native test App')
    parser.add_argument('--proposals', action='store_true', help='Whole proposal, inline passwords and originals through the production shell and an AOT CLI')
    parser.add_argument('--proposals-os-input', action='store_true', help='With --proposals, wait for synthetic text typed into the real secure field')
    parser.add_argument('--real-codex-project', type=Path, help='Existing approved synthetic project; no hook/trust changes')
    parser.add_argument('--package', type=Path, help='Candidate payload for real Codex CLI')
    parser.add_argument('--file-codex', action='store_true', help='Real AI ordinary-file request/approval/history with the existing approved project')
    args = parser.parse_args()
    real_codex = args.real_codex_project is not None
    if args.proposals_os_input and not args.proposals:
        parser.error('--proposals-os-input requires --proposals')
    if args.proposals and (args.workflow or real_codex or args.file_codex):
        parser.error('--proposals is a separate synthetic scenario')
    if args.file_codex and not real_codex:
        parser.error('--file-codex requires --real-codex-project and --package')
    if real_codex != (args.package is not None) or (real_codex and args.workflow):
        parser.error('Use --real-codex-project with --package, separately from --workflow')
    if real_codex:
        approved = ROOT / 'build/macos-adaptation/issue49-codex-preparation-1/独立 Mac Codex 验收项目'
        if args.real_codex_project.resolve() != approved.resolve():
            parser.error('Only the explicitly approved synthetic project is supported')
        with socket.socket() as listener:
            listener.settimeout(1)
            if listener.connect_ex(('127.0.0.1', 47125)) == 0:
                parser.error('Existing service on 47125; do not replace it')
    target = 'integration_test/owner_workflow_native_test.dart' if args.workflow else TARGET
    if real_codex:
        target = 'integration_test/owner_codex_native_test.dart'
    if args.proposals:
        target = 'integration_test/owner_proposals_native_test.dart'
    workflow_run = uuid.uuid4().hex
    phase_data = []
    OUTPUT = args.output.resolve()
    OUTPUT.relative_to(ROOT / 'build/macos-adaptation')
    OUTPUT.mkdir(parents=True, exist_ok=False)
    products = OUTPUT / 'products'
    config = OUTPUT / 'OwnerCheck.xcconfig'
    config.write_text(f'PRODUCT_BUNDLE_IDENTIFIER = {IDENTITY}\n'
                      'AGENT_INFO_INTERFACE_PREVIEW = NO\n'
                      f'CONFIGURATION_BUILD_DIR = {products}\n'
                      f'DWARF_DSYM_FOLDER_PATH = {products}\n')
    preview = DESKTOP / 'build/macos/Build/Products/Debug/info_desktop.app'
    def preview_hash():
        binary = preview / 'Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/kernel_blob.bin'
        return hashlib.sha256(binary.read_bytes()).hexdigest() if binary.exists() else None
    original = preview_hash()
    if preview.is_symlink():
        raise RuntimeError('Refuse a linked Debug preview')
    # Preserve exact bytes as well as using a separate Xcode build database.
    # A shared derived-data root can delete the previous target's App as stale.
    preserved = OUTPUT / 'preserved-preview'
    if preview.exists():
        shutil.copytree(preview, preserved, symlinks=True)
    env = dict(os.environ, XCODE_XCCONFIG_FILE=str(config),
               FLUTTER_MACOS_ARM64_ONLY='true',
               ZHIYU_PROFILE_DRIVER_REPORT=str(OUTPUT / 'driver.json'),
               PUB_CACHE=str(ROOT / '.cache/pub'),
               DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
    launcher = str(ROOT / 'scripts/dev-macos.sh')
    report = {'complete': False, 'previewKernelSha256': original, 'workflowRun': workflow_run if args.workflow or real_codex else None}
    def run(args, name, timeout=600):
        print(f'{name}: started', flush=True)
        with (OUTPUT / name).open('w') as log:
            result = subprocess.run(args, cwd=DESKTOP, env=env, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=timeout)
        print(f'{name}: exit {result.returncode}', flush=True)
        result.check_returncode()
    try:
        run([launcher, 'flutter', 'build', 'macos', '--debug', '--config-only',
             '--no-pub', '--target', target, '--dart-define=OWNER_NATIVE_SYNTHETIC=true',
             '--dart-define=OWNER_NATIVE_WORKFLOW_RUN=' + workflow_run,
             '--dart-define=OWNER_PROPOSALS_OS_INPUT=' + str(args.proposals_os_input).lower(),
             '--dart-define=OWNER_NATIVE_FILE_CODEX=' + str(args.file_codex).lower(),
             '--dart-define=INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE=false'], 'configure.log')
        run(['xcodebuild', '-workspace', 'macos/Runner.xcworkspace', '-scheme', 'Runner',
             '-configuration', 'Debug', '-derivedDataPath', str(OUTPUT / 'xcode'),
             '-destination', 'generic/platform=macOS',
             'OBJROOT=' + str(OUTPUT / 'xcode/Build/Intermediates.noindex'),
             'SYMROOT=' + str(products), 'ARCHS=arm64',
             'COMPILER_INDEX_STORE_ENABLE=NO', '-quiet'], 'build.log')
        app = products / 'info_desktop.app'
        if args.proposals:
            helper = app / 'Contents/MacOS/info-proposal-check'
            with (OUTPUT / 'compile-cli.log').open('w') as log:
                subprocess.run([launcher, 'dart', 'compile', 'exe', '--target-os', 'macos', '--target-arch', 'arm64',
                                'bin/info.dart', '-o', str(helper)], cwd=ROOT / 'packages/info_cli', env=env,
                               stdout=log, stderr=subprocess.STDOUT, timeout=300, check=True)
            run(['codesign', '--force', '--sign', '-', '--entitlements',
                 str(DESKTOP / 'macos/Runner/Worker.entitlements'), str(helper)], 'sign-cli.log')
            run(['codesign', '--force', '--sign', '-', '--preserve-metadata=entitlements,flags', str(app)], 'resign.log')
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        if info['CFBundleIdentifier'] != IDENTITY or info.get('AgentInfoInterfacePreview') == 'YES':
            raise RuntimeError('Unexpected native test identity')
        signed = subprocess.run(['codesign', '-d', '--entitlements', '-', '--xml', str(app)],
                                capture_output=True, check=True)
        if plistlib.loads(signed.stdout).get('com.apple.security.app-sandbox') is not True:
            raise RuntimeError('Native check must remain sandboxed')
        run(['codesign', '--verify', '--deep', '--strict', str(app)], 'signature.log')
        kernel = app / 'Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/kernel_blob.bin'
        fixed_kernel = hashlib.sha256(kernel.read_bytes()).hexdigest()
        for phase in (['live', 'reopen'] if args.workflow else ['basic']):
            driver_file = OUTPUT / ('driver-' + phase + '.json' if args.workflow else 'driver.json')
            env['ZHIYU_PROFILE_DRIVER_REPORT'] = str(driver_file)
            command = [launcher, 'flutter', 'drive', '--debug', '-d', 'macos', '--no-pub',
                 '--target', target, '--driver', 'integration_test/profile_driver.dart',
                 '--use-application-binary', str(app)]
            if real_codex:
                env['ZHIYU_PROFILE_DRIVER_TIMEOUT_SECONDS'] = '900'
                drive_with_real_client(command, OUTPUT, env, workflow_run,
                                       args.real_codex_project.resolve(), args.package.resolve(),
                                       'owner-file-ui' if args.file_codex else 'owner-ui')
            else:
                run(command, 'drive-' + phase + '.log', 300)
            data = json.loads(driver_file.read_text())
            if not isinstance(data, dict):
                raise RuntimeError('Driver returned no scenario evidence; an empty test run is not a pass')
            expected = 9 if args.proposals else ((9 if phase == 'live' else 3) if args.workflow else (11 if args.file_codex else 6))
            if data.get('runtime', {}).get('platform') != 'macos' or len(data.get('checks', [])) != expected:
                raise RuntimeError('Missing native check evidence')
            if args.workflow:
                if data.get('passed') is not True or data.get('phase') != phase:
                    raise RuntimeError('Native fixture did not advance across launches')
                expected_images = {'partial-approval', 'approval-snapshot'} if phase == 'live' else {'reopened-library'}
                images = data.pop('imagesPngBase64')
                if set(images) != expected_images:
                    raise RuntimeError('Missing native workflow screenshots')
                for name, value in images.items():
                    (OUTPUT / (name + '.png')).write_bytes(base64.b64decode(value))
                phase_data.append(data)
            else:
                (OUTPUT / ('real-ai-approval.png' if real_codex else 'saved-library.png')).write_bytes(base64.b64decode(data.pop('imagePngBase64')))
                if args.proposals:
                    if data.get('passed') is not True or data.get('fixtureRemoved') is not True:
                        raise RuntimeError('Proposal flow or fixture cleanup incomplete')
                    if args.proposals_os_input and data.get('nativePasswordInput') is not True:
                        raise RuntimeError('Native secure keyboard input was not exercised')
                    images = data.pop('imagesPngBase64')
                    if set(images) != {'password', 'original', 'modification'}:
                        raise RuntimeError('Missing proposal screens')
                    for name, value in images.items():
                        (OUTPUT / (name + '.png')).write_bytes(base64.b64decode(value))
                    report['proposals'] = data
            if real_codex:
                if data.get('passed') is not True or data.get('fixtureRemoved') is not True:
                    raise RuntimeError('Missing real-client native UI or cleanup evidence')
                report['nativeOwnerUi'] = data
                report['realClient'] = json.loads((OUTPUT / 'real-client/real-client-result.json').read_text())['results']
                completion = 'completeOwnerFileUiFlow' if args.file_codex else 'completeOwnerUiFlow'
                if report['realClient'].get(completion) is not True or report['realClient'].get('failure'):
                    raise RuntimeError('Real AI scenario incomplete; native cleanup is not acceptance')
            driver_file.write_text(json.dumps(data, indent=2))
            if hashlib.sha256(kernel.read_bytes()).hexdigest() != fixed_kernel:
                raise RuntimeError('Native App changed during validation')
        if args.workflow:
            if phase_data[0]['pid'] == phase_data[1]['pid'] or phase_data[0]['fixtureDirectory'] != phase_data[1]['fixtureDirectory']:
                raise RuntimeError('Expected distinct native processes reopening the same synthetic library')
            if phase_data[1].get('fixtureRemoved') is not True:
                raise RuntimeError('Native synthetic library was not cleaned')
            report['phases'] = phase_data
            report['nativeKernelSha256'] = fixed_kernel
            report['scope'] = phase_data[0]['scope']
        report['complete'] = True
    finally:
        if original != preview_hash():
            if preview.exists():
                shutil.rmtree(preview)
            if preserved.exists():
                preserved.rename(preview)
            report['previewRestoredFromPreservedBytes'] = True
        report['previewUnchanged'] = original == preview_hash()
        if preserved.exists():
            shutil.rmtree(preserved)
        # Only this invocation's output tree; no installed or pre-existing App.
        binary = str(products / 'info_desktop.app/Contents/MacOS/info_desktop')
        processes = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True)
        still_running = any(line.strip().split(None, 1)[-1] == binary
                            for line in processes.splitlines() if line.strip())
        report['processStillRunning'] = still_running
        if products.exists() and not still_running:
            shutil.rmtree(products)
        if (OUTPUT / 'xcode').exists() and not still_running:
            shutil.rmtree(OUTPUT / 'xcode')
        if (args.workflow or real_codex) and not still_running:
            # Remove only this invocation's unique, marked synthetic directory.
            for path in OUTPUT.glob('driver-*.json'):
                data = json.loads(path.read_text())
                directory = data.get('fixtureDirectory') if isinstance(data, dict) else None
                if not directory:
                    continue
                fixture = Path(directory)
                if not fixture.exists():
                    continue
                resolved = fixture.resolve()
                allowed = [ROOT / '.cache/tmp', Path.home() / 'Library/Containers' / IDENTITY / 'Data']
                if (fixture.is_symlink() or fixture.name != 'owner-workflow-' + workflow_run or
                        not any(resolved.is_relative_to(base.resolve()) for base in allowed) or
                        (fixture / 'fixture-marker').read_text() != 'disposable-owner-ui-v1'):
                    raise RuntimeError('Unexpected native fixture path; preserved for inspection')
                shutil.rmtree(fixture)
                report['failedFixtureCleaned'] = True
        report['temporaryProductsRemoved'] = not products.exists()
        (OUTPUT / 'result.json').write_text(json.dumps(report, indent=2))
    if not report['previewUnchanged']:
        raise RuntimeError('Preview changed unexpectedly')
    if report['processStillRunning']:
        raise RuntimeError('Native check still running; retained its products')
    print(json.dumps(report))


if __name__ == '__main__':
    main()
