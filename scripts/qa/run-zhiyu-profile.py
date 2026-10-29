"""Run isolated Profile/AOT checks in the one fixed preview; always restore it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
IDENTITY = 'com.example.infoDesktop.zhiyuPreview'


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')


def run_command(args, log, env, cwd):
    started = time.monotonic()
    print(f'{log.name}: started', flush=True)
    with log.open('w') as output:
        result = subprocess.run(args, cwd=cwd, env=env, stdout=output,
                                stderr=subprocess.STDOUT, check=False)
    print(f'{log.name}: exit {result.returncode}', flush=True)
    return {'exitCode': result.returncode, 'seconds': time.monotonic() - started}


def inspect_app(app, aot=False):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if (info.get('CFBundleIdentifier') != IDENTITY or
            info.get('AgentInfoInterfacePreview') not in (True, 'YES')):
        raise ValueError('Refuse to launch or replace a non-preview application')
    executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
    if subprocess.check_output(['lipo', '-archs', str(executable)], text=True).strip() != 'arm64':
        raise ValueError('The fixed preview must be ARM64 only')
    signed = subprocess.run(['codesign', '-d', '--entitlements', '-', '--xml', str(app)],
                            capture_output=True, check=True)
    entitlements = plistlib.loads(signed.stdout)
    if entitlements.get('com.apple.security.app-sandbox') is not True:
        raise ValueError('The preview sandbox must remain enabled')
    if any('worker' in p.name.lower() for p in app.rglob('*') if p.is_file()):
        raise ValueError('Production worker must not be packaged in this preview')
    framework = app / 'Contents/Frameworks/App.framework/Versions/A/App'
    kernel = app / 'Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/kernel_blob.bin'
    result = {'bundleIdentifier': IDENTITY, 'sandboxed': True, 'architecture': 'arm64',
              'executableSha256': hashlib.sha256(executable.read_bytes()).hexdigest(),
              'frameworkSha256': hashlib.sha256(framework.read_bytes()).hexdigest(),
              'kernelPresent': kernel.exists()}
    symbols = subprocess.check_output(['nm', '-g', str(framework)], text=True,
                                      stderr=subprocess.DEVNULL)
    # The pinned Dart 3.13 engine uses unified snapshot exports, not the older
    # kDartIsolateSnapshotInstructions naming. Require both actual exports.
    exports = {line.split()[-1] for line in symbols.splitlines() if line.split()}
    expected = {'_kDartSnapshotData', '_kDartSnapshotText'}
    result['aotSnapshotSymbolsPresent'] = expected.issubset(exports)
    result['aotSnapshotExports'] = sorted(exports & expected)
    if aot:
        if kernel.exists() or not result['aotSnapshotSymbolsPresent']:
            raise ValueError('Expected clean AOT assets: ' + json.dumps(result))
    return result


def one_app(products, expected):
    apps = list(products.rglob('*.app'))
    if apps != [expected]:
        raise ValueError('Expected exactly the one fixed preview App; no automatic removal')


def run(output, library, python, runs):
    desktop = ROOT / 'apps/desktop'
    products = desktop / 'build/macos/Build/Products'
    app = products / 'Debug/info_desktop.app'
    normal_config = desktop / 'macos/Runner/Configs/Preview.xcconfig'
    launcher = ROOT / 'scripts/dev-macos.sh'
    target = 'integration_test/zhiyu_library_native_test.dart' if library else 'integration_test/zhiyu_foundation_native_test.dart'
    if not output.is_relative_to(ROOT / 'build/zhiyu-ui') or output.exists():
        raise ValueError('Choose a NEW output directory inside build/zhiyu-ui')
    one_app(products, app)
    initial = inspect_app(app)
    if not initial['kernelPresent'] or initial['aotSnapshotSymbolsPresent']:
        raise ValueError('Start with the ordinary Debug preview before profiling')
    initial_symbols = set(products.rglob('*.dSYM'))
    output.mkdir(parents=True)
    config = output / 'Profile.xcconfig'
    if any(c in str(ROOT) for c in ['\n', '"', '$']):
        raise ValueError('Unsupported Xcode project path')
    config.write_text(f'#include "{normal_config}"\n'
                      f'CONFIGURATION_BUILD_DIR = {products / "Debug"}\n'
                      f'DWARF_DSYM_FOLDER_PATH = {products / "Debug"}\n', encoding='utf-8')
    base = {**os.environ, 'FLUTTER_MACOS_ARM64_ONLY': 'true'}
    profile_env = {**base, 'XCODE_XCCONFIG_FILE': str(config)}
    normal_env = {**base, 'XCODE_XCCONFIG_FILE': str(normal_config)}
    report = {'target': target, 'fixedApp': str(app), 'initial': initial, 'runs': [],
              'ordinaryRestorePassed': False, 'allProfileChecksPassed': False}
    failure = None
    products_mutated = False
    try:
        prepared = run_command([str(launcher), 'flutter', 'build', 'macos', '--profile',
                             '--config-only', '--no-pub', '--target', target,
                             '--dart-define=ZHIYU_REQUIRED_PROFILE=true',
                             '--dart-define=INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE=false'],
                            output / 'profile-config.log', profile_env, desktop)
        report['configuration'] = prepared
        if prepared['exitCode']:
            raise RuntimeError('Profile configuration failed; see profile-config.log')
        # Build modes normally have separate product folders. This explicitly
        # shared folder must not inherit the preceding mode's kernel/snapshot.
        generated = [app, products / 'Debug/App.framework']
        for path in generated:
            if path.is_symlink():
                raise ValueError('Refuse a symlink at the fixed generated product')
        products_mutated = True
        for path in generated:
            if path.exists():
                shutil.rmtree(path)
        # Flutter's build command hard-codes Products/Profile during its final
        # size lookup. Use its prepared workspace and the same Xcode build
        # arguments directly so there is still only one App in Products/Debug.
        build = run_command(['xcodebuild', '-workspace', 'macos/Runner.xcworkspace',
                             '-scheme', 'Runner', '-configuration', 'Profile',
                             '-derivedDataPath', str(desktop / 'build/macos'),
                             '-destination', 'generic/platform=macOS',
                             'OBJROOT=' + str(desktop / 'build/macos/Build/Intermediates.noindex'),
                             'SYMROOT=' + str(products), 'ARCHS=arm64',
                             'COMPILER_INDEX_STORE_ENABLE=NO', '-quiet'],
                            output / 'profile-build.log', profile_env, desktop)
        report['build'] = build
        if build['exitCode']:
            raise RuntimeError('Profile build failed; see profile-build.log')
        one_app(products, app)
        report['profileApp'] = inspect_app(app, aot=True)
        for index in range(runs):
            folder = output / f'run-{index + 1:02}'
            folder.mkdir()
            data_file = folder / 'driver-data.json'
            driver_env = {**profile_env, 'ZHIYU_PROFILE_DRIVER_REPORT': str(data_file)}
            driven = run_command([str(launcher), 'flutter', 'drive', '--profile', '-d', 'macos',
                                  '--no-pub', '--target', target,
                                  '--driver', 'integration_test/profile_driver.dart',
                                  '--use-application-binary', str(app)],
                                 folder / 'drive.log', driver_env, desktop)
            data = json.loads(data_file.read_text()) if data_file.exists() else {}
            runtime = data.get('runtime', {}) if isinstance(data, dict) else {}
            result = {'driverExitCode': driven['exitCode'], 'allTestsPassed': driven['exitCode'] == 0,
                      'runtime': runtime, 'profileApp': report['profileApp'],
                      'seconds': driven['seconds']}
            write_json(folder / 'profile-result.json', result)
            report['runs'].append(result)
            if (driven['exitCode'] or runtime.get('profileMode') is not True or
                    runtime.get('debugMode') is not False or runtime.get('platform') != 'macos'):
                raise RuntimeError('Profile driver failed or did not attest Profile mode')
            if inspect_app(app, aot=True) != report['profileApp']:
                raise RuntimeError('The prebuilt profile application changed during a run')
            collected = run_command([python, str(ROOT / 'scripts/qa/collect-zhiyu-native.py'),
                                     '--log', str(folder / 'drive.log'),
                                     '--profile-result', str(folder / 'profile-result.json'),
                                     '--output', str(folder / 'native'), '--python', python],
                                    folder / 'collection.log', base, ROOT)
            if collected['exitCode']:
                raise RuntimeError('Profile evidence collection failed')
        report['allProfileChecksPassed'] = True
    except Exception as error:
        failure = error
        report['error'] = str(error)
    finally:
        if products_mutated:
            for path in [app, products / 'Debug/App.framework']:
                if path.is_symlink():
                    raise ValueError('Refuse a symlink during preview restoration')
                if path.exists():
                    shutil.rmtree(path)
            restored = run_command([str(launcher), 'flutter', 'build', 'macos', '--debug',
                                    '--no-pub', '--target', 'lib/preview_main.dart'],
                                   output / 'restore.log', normal_env, desktop)
            report['restore'] = restored
            try:
                if restored['exitCode'] == 0:
                    restored_app = inspect_app(app)
                    if (not restored_app['kernelPresent'] or
                            restored_app['aotSnapshotSymbolsPresent']):
                        raise RuntimeError('Ordinary Debug preview did not restore its JIT kernel')
                    one_app(products, app)
                    report['restoredApp'] = restored_app
                    report['ordinaryRestorePassed'] = True
            except Exception as error:
                report['restoreError'] = str(error)
            # Remove only symbol bundles generated by this scoped build. Never
            # touch pre-existing Release symbols or SDK caches.
            removed = []
            for path in set(products.rglob('*.dSYM')) - initial_symbols:
                if not path.is_relative_to(products / 'Debug'):
                    report.setdefault('unexpectedSymbolOutputs', []).append(str(path))
                    continue
                removed.append(str(path))
                if path.is_symlink():
                    path.unlink()
                else:
                    shutil.rmtree(path)
            report['newDebugSymbolsRemoved'] = sorted(removed)
        else:
            report['initialAppUnchanged'] = True
            report['restore'] = {'performed': False, 'reason': 'Products were not mutated'}
        write_json(output / 'result.json', report)
    if failure or not report['ordinaryRestorePassed'] or report.get('unexpectedSymbolOutputs'):
        raise RuntimeError(report.get('error', 'Ordinary preview restoration failed'))
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--library', action='store_true')
    parser.add_argument('--python', default=sys.executable)
    parser.add_argument('--runs', type=int, choices=range(1, 4), default=1)
    args = parser.parse_args()
    output = (ROOT / args.output).resolve()
    print(json.dumps(run(output, args.library, args.python, args.runs)))


if __name__ == '__main__':
    main()
