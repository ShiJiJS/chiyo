#!/usr/bin/env python3
"""Package committed Mac source in a disposable checkout, preserving the preview.

Only the checked-in commit is copied; machine-local untracked files are neither
read nor moved. Keep one payload and ZIP; remove duplicate extracted Apps,
diagnostic build products, dSYMs and the isolated checkout after verification.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='New directory under build/macos-adaptation')
    args = parser.parse_args()
    out = args.output.resolve()
    out.relative_to(ROOT / 'build/macos-adaptation')
    out.mkdir(parents=True, exist_ok=False)
    source = out / 'source'
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    preview = ROOT / 'apps/desktop/build/macos/Build/Products/Debug/info_desktop.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/kernel_blob.bin'
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    preview_digest = lambda: digest(preview) if preview.is_file() else None
    report = {'sourceCommit': commit, 'complete': False, 'phases': [],
              'previewBefore': preview_digest()}
    env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')

    def run(name, command, cwd=ROOT, timeout=600):
        print(name + ': started', flush=True)
        with (out / (name + '.log')).open('w') as log:
            result = subprocess.run(command, cwd=cwd, env=env, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=timeout)
        report['phases'].append({'name': name, 'exit': result.returncode})
        print(name + ': ' + str(result.returncode), flush=True)
        result.check_returncode()

    try:
        run('clone', ['git', 'clone', '--shared', '--no-checkout', '--quiet', str(ROOT), str(source)])
        run('sparse', ['git', 'sparse-checkout', 'set', 'apps/desktop', 'apps/server',
                       'packages', 'scripts', 'integrations', 'third_party'], source)
        run('checkout', ['git', 'checkout', '--detach', commit], source)
        with (source / '.git/info/exclude').open('a') as excluded:
            excluded.write('\n/.tools\n/.cache/\n/.downloads\n')
        (source / '.tools').symlink_to(ROOT / '.tools', target_is_directory=True)
        (source / '.cache').mkdir()
        (source / '.cache/pub').symlink_to(ROOT / '.cache/pub', target_is_directory=True)
        # Downloads remain verified by bundle-macos-tools.py. Sharing this known
        # cache does not expose untracked source or alter the installed payload.
        (ROOT / '.downloads').mkdir(exist_ok=True)
        (source / '.downloads').symlink_to(ROOT / '.downloads', target_is_directory=True)
        launcher = str(source / 'scripts/dev-macos.sh')
        for package in ['info_core', 'info_cli', 'info_storage']:
            run('pub-' + package, [launcher, 'dart', 'pub', 'get', '--enforce-lockfile'], source / 'packages' / package)
        run('pub-desktop', [launcher, 'flutter', 'pub', 'get', '--enforce-lockfile'], source / 'apps/desktop')
        run('package', [sys.executable, str(source / 'scripts/package-macos.py'), str(source / 'build/package')], source, 1200)
        package = source / 'build/package'
        verified = json.loads((package / 'verification.json').read_text())
        manifest = json.loads((package / 'chiyo/manifest.json').read_text())
        if (not verified.get('complete') or manifest['sourceCommit'] != commit
                or manifest['sourceDirty'] is not False or not all(p['exit'] == 0 for p in verified['phases'])):
            raise RuntimeError('Missing fixed-source package verification')
        report['package'] = verified
        report['release'] = manifest['release']
        # The package verifier has already compared the extracted tree byte for
        # byte. Keep only its evidence, one usable payload, and the archive.
        for name in ['chiyo', verified['archive'], verified['archive'] + '.sha256',
                     verified['diskImage'], verified['diskImage'] + '.sha256',
                     'verification.json', 'logs']:
            shutil.move(str(package / name), str(out / name))
        if digest(out / verified['archive']) != verified['archiveSha256']:
            raise RuntimeError('Moved archive differs')
        if digest(out / verified['diskImage']) != verified['diskImageSha256']:
            raise RuntimeError('Moved disk image differs')
        report['complete'] = True
    finally:
        processes = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True)
        live = any(line.strip().split(None, 1)[-1].startswith(str(source) + '/')
                   for line in processes.splitlines() if line.strip())
        report['sourceProcessStillRunning'] = live
        if source.exists() and not live:
            failed = source / 'build/package'
            if failed.exists() and not report['complete']:
                if (failed / 'logs').is_dir():
                    shutil.copytree(failed / 'logs', out / 'failed-package-logs')
                if (failed / 'verification.json').is_file():
                    shutil.copy2(failed / 'verification.json', out / 'failed-verification.json')
            shutil.rmtree(source)
        report['temporaryCheckoutRemoved'] = not source.exists()
        report['previewPreserved'] = preview_digest() == report['previewBefore']
        (out / 'result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    if live or not report['previewPreserved']:
        raise RuntimeError('Package checkout/preview lifecycle not preserved')
    print(json.dumps(report, ensure_ascii=False))


if __name__ == '__main__':
    main()
