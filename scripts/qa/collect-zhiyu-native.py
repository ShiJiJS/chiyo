#!/usr/bin/env python3
"""Collect the just-completed preview's own evidence; encode outside its sandbox."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--log', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--python', required=True)
    parser.add_argument('--profile-result', type=Path)
    args = parser.parse_args()
    log = args.log.read_text()
    profile = None
    if args.profile_result:
        profile = json.loads(args.profile_result.read_text())
        if (profile.get('allTestsPassed') is not True or profile.get('driverExitCode') != 0 or
                profile.get('runtime', {}).get('profileMode') is not True or
                profile.get('profileApp', {}).get('sandboxed') is not True or
                profile.get('profileApp', {}).get('aotSnapshotSymbolsPresent') is not True):
            raise ValueError('Expected a passed, sandboxed AOT driver result')
    elif 'All tests passed!' not in log:
        raise ValueError('Collect only a successfully completed native check')
    matches = re.findall(r'^ZHIYU_NATIVE_EVIDENCE=(.+)$', log, re.M)
    if profile:
        source = Path(profile['runtime']['nativeEvidenceDirectory'])
    elif len(matches) != 1:
        raise ValueError('Expected exactly one owned evidence directory')
    else:
        source = Path(matches[0])
    if not source.name.startswith('ZhiyuUI-'):
        raise ValueError('Unexpected temporary evidence directory name')
    uuid.UUID(source.name.removeprefix('ZhiyuUI-'))
    expected = Path.home() / 'Library/Containers/com.example.infoDesktop.zhiyuPreview/Data/tmp'
    if source.parent.resolve() != expected.resolve() or source.is_symlink():
        raise ValueError('Evidence must belong to the isolated preview container')
    result = json.loads((source / 'native-checks.json').read_text())
    if not result.get('nativeIsolationChecked'):
        raise ValueError('Native isolation was not checked')
    if profile and result.get('runtime') != profile['runtime']:
        raise ValueError('Native receipt and driver runtime must agree')
    if any(p.is_symlink() for p in source.rglob('*')):
        raise ValueError('Evidence must not contain symlinks')
    if args.output.exists():
        raise FileExistsError('Choose a new output directory; never overwrite evidence')
    shutil.copytree(source, args.output)
    command = [args.python, str(ROOT / 'scripts/qa/encode-native-ui-recording.py'),
               '--manifest', str(args.output / 'native-controls.json')]
    stills = args.output / 'native-stills.json'
    if stills.exists():
        command += ['--stills-manifest', str(stills)]
    subprocess.run(command, check=True)
    shutil.rmtree(source)
    print(json.dumps({'output': str(args.output), 'checks': result['checks'],
                      'temporarySourceRemoved': True}, ensure_ascii=False))


if __name__ == '__main__':
    main()
