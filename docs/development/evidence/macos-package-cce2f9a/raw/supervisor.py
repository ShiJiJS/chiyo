from pathlib import Path
import hashlib
import json
import os
import shutil
import stat
import subprocess

ROOT = Path('/Users/jiangxinyi/Documents/Project/agent-info')
OUTPUT = ROOT / 'build/macos-adaptation/issue50-package-13'
REPORT = ROOT / 'build/macos-adaptation/issue50-package-13-job.json'
SNAPSHOT = ROOT / 'docs/development/evidence/macos-inbox-status-counts/raw/source-check-completion-hashes.json'
STATE = {'complete': False, 'separateSourcePassed': 720,
         'separateSourceConditionalSkipped': 66, 'cleanup': [], 'unregister': []}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save():
    REPORT.write_text(json.dumps(STATE, ensure_ascii=False, indent=2) + '\n')


def verify_sources():
    snapshot = json.loads(SNAPSHOT.read_text())
    for name, expected in snapshot['files'].items():
        assert sha(ROOT / name) == expected, name
    return len(snapshot['files'])


assert subprocess.check_output(['git', 'branch', '--show-current'], cwd=ROOT, text=True).strip() == 'codex/macos-adaptation'
assert not subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT)
assert not OUTPUT.exists()
assert not (ROOT / 'apps/desktop/build/macos').exists()
STATE.update(sourceCommit=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
             sourceSnapshotSha256=sha(SNAPSHOT), sourceInputsVerifiedBefore=verify_sources(),
             packageSourceChecksRequested=False,
             sourceCheckScope='Full check already passed; all 637 checked source bytes match committed inputs before and after packaging')
save()
try:
    with (ROOT / 'build/macos-adaptation/issue50-package-13-run.txt').open('wb') as log:
        result = subprocess.run(['python3', 'scripts/package-macos.py', str(OUTPUT)],
                                cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=1200)
    STATE['packageExitCode'] = result.returncode
    assert result.returncode == 0
    package = json.loads((OUTPUT / 'verification.json').read_text())
    assert package['complete'] and package['sourceCommit'] == STATE['sourceCommit']
    assert len(package['phases']) == 20 and all(row['exit'] == 0 for row in package['phases'])
    archive = OUTPUT / package['archive']
    assert sha(archive) == package['archiveSha256']
    final = OUTPUT / package['extractedDirectory']
    shutil.copy2(final / 'manifest.json', OUTPUT / 'preserved-manifest.json')
    manifest = json.loads((OUTPUT / 'preserved-manifest.json').read_text())
    assert manifest['sourceChecksRequested'] is False
    STATE.update(archive=str(archive.relative_to(ROOT)), archiveBytes=archive.stat().st_size,
                 archiveSha256=package['archiveSha256'], manifestSha256=sha(OUTPUT / 'preserved-manifest.json'),
                 packagePhasesPassed=len(package['phases']), sourceInputsVerifiedAfter=verify_sources(),
                 packageVerified=True)
except Exception as error:
    STATE['failure'] = type(error).__name__ + ': ' + str(error)
finally:
    # The generated native build root did not exist before this job. These are
    # the exact package/build outputs; never remove the stable install or SDKs.
    targets = [OUTPUT / 'AgentInfoManage', OUTPUT / 'verify', OUTPUT / 'diagnostic-build',
               ROOT / 'apps/desktop/build/macos', ROOT / 'apps/desktop/.dart_tool/flutter_build',
               ROOT / 'apps/desktop/.dart_tool/hooks_runner']
    for target in targets:
        if not target.exists():
            continue
        assert not target.is_symlink() and target.resolve().is_relative_to(ROOT)
        for app in target.rglob('info_desktop.app'):
            assert not app.is_symlink() and app.resolve().is_relative_to(target.resolve())
            result = subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister',
                                     '-u', str(app)], capture_output=True, timeout=30)
            STATE['unregister'].append({'path': str(app.relative_to(ROOT)), 'exitCode': result.returncode})
        allocated = int(subprocess.check_output(['/usr/bin/du', '-sk', str(target)], text=True).split()[0])
        shutil.rmtree(target)
        STATE['cleanup'].append({'path': str(target.relative_to(ROOT)), 'allocatedKiB': allocated,
                                 'removed': not target.exists()})
    stable = ROOT / 'local/中文 Mac 预览/AgentInfoManage'
    manifest = json.loads((stable / 'manifest.json').read_text())
    mismatches = []
    for entry in manifest['files']:
        path = stable / entry['path']
        if 'link' in entry:
            valid = path.is_symlink() and os.readlink(path) == entry['link']
        else:
            valid = path.is_file() and path.stat().st_size == entry['bytes'] and stat.S_IMODE(path.stat().st_mode) == entry['mode'] and sha(path) == entry['sha256']
        if not valid:
            mismatches.append(entry['path'])
    STATE.update(stableItemsVerified=len(manifest['files']), stableMismatches=mismatches,
                 stableSignatureExit=subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict',
                     str(stable / 'app/info_desktop.app')], capture_output=True).returncode,
                 stablePid53592Alive=subprocess.run(['kill', '-0', '53592'], capture_output=True).returncode == 0)
    apps, symbols = [], []
    for base in [ROOT / 'build/macos-adaptation', ROOT / 'local', ROOT / 'apps/desktop/build']:
        for directory, folders, files in os.walk(base, followlinks=False):
            for name in list(folders):
                path = Path(directory) / name
                if path.is_symlink():
                    folders.remove(name)
                elif name.endswith('.app'):
                    apps.append(str(path.relative_to(ROOT)))
                    folders.remove(name)
                elif name.endswith('.dSYM'):
                    symbols.append(str(path.relative_to(ROOT)))
                    folders.remove(name)
    STATE.update(remainingApps=apps, remainingGeneratedDsyms=symbols,
                 releasedAllocatedKiB=sum(row['allocatedKiB'] for row in STATE['cleanup']))
    STATE['complete'] = bool(STATE.get('packageVerified') and not mismatches and
        STATE['stableSignatureExit'] == 0 and STATE['stablePid53592Alive'] and len(apps) == 1 and not symbols)
    save()
print(json.dumps({'complete': STATE['complete'], 'archive': STATE.get('archive'),
                  'cleanupTargets': len(STATE['cleanup'])}), flush=True)
raise SystemExit(0 if STATE['complete'] else 1)
