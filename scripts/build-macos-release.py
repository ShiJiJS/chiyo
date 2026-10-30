#!/usr/bin/env python3
"""Build with the pinned Flutter AOT windowing workaround, then restore the SDK.

Flutter #191575 / Dart f9bd4cef fixes an unretained FFI trampoline snapshot crash.
Our pinned 3.47.7 still reproduces it. This app uses the established Cocoa runner,
not Flutter's experimental windowing API. Only this build compiles that flag as
false; no application feature or FFI implementation is replaced.
"""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
from pathlib import Path
import signal
import subprocess

REVISION = 'abaf9c523780a608bd46686fd5e53740a07077f8'
RELATIVE = 'packages/flutter/lib/src/foundation/_features.dart'
ORIGINAL_SHA256 = '34335494e2a8128f873b69f8cb16bada88cf190e9d582d8802ae7027a5e22c28'
OLD = b"bool isWindowingEnabled = debugEnabledFeatureFlags.contains('windowing');"
NEW = b'bool isWindowingEnabled = false;'


@contextmanager
def temporary_source(path, original, patched):
    """Preserve unknown edits; a known interrupted patch can be recovered."""
    current = path.read_bytes()
    if current not in (original, patched):
        raise RuntimeError('SDK source has unrelated modifications; refusing to overwrite it')
    path.write_bytes(patched)
    try:
        yield
    finally:
        if path.read_bytes() != patched:
            raise RuntimeError('SDK source changed during build; preserving it for inspection')
        path.write_bytes(original)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('sdk', type=Path)
    parser.add_argument('--restore-sdk', action='store_true')
    args, flutter_args = parser.parse_known_args()
    sdk = args.sdk.resolve(strict=True)
    if subprocess.check_output(['git', '-C', str(sdk), 'rev-parse', 'HEAD'], text=True).strip() != REVISION:
        raise RuntimeError('Reassess the workaround for the new Flutter revision')
    original = subprocess.check_output(['git', '-C', str(sdk), 'show', f'{REVISION}:{RELATIVE}'])
    if hashlib.sha256(original).hexdigest() != ORIGINAL_SHA256 or original.count(OLD) != 1:
        raise RuntimeError('Pinned SDK source checksum does not match')
    patched = original.replace(OLD, NEW)
    path = sdk / RELATIVE
    if path.is_symlink():
        raise RuntimeError('Refusing a symlinked SDK source')
    # Serialize SDK source changes across independent shells as well as this
    # task. The lock is intentionally outside the SDK's Git worktree.
    with (sdk.parent / '.macos-aot-build.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with temporary_source(path, original, patched):
            if args.restore_sdk:
                return 0
            print('Mac AOT compatibility: Flutter #191575; temporary experimental windowing exclusion', flush=True)
            print('SDK original SHA256: ' + ORIGINAL_SHA256, flush=True)
            print('SDK build SHA256: ' + hashlib.sha256(patched).hexdigest(), flush=True)
            return subprocess.call([str(sdk / 'bin/flutter'), 'build', 'macos', '--release', '--no-pub', *flutter_args])


if __name__ == '__main__':
    def interrupted(signum, frame):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, interrupted)
    raise SystemExit(main())
