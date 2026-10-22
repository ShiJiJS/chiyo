"""Run schema21 -> 22 / conditional backup10 checks with real Mac SQLCipher.

Uses an unchanged committed old Mac reader and a frozen working-source copy.
Only disposable synthetic data and in-memory test keys; no Keychain, owner
profile, Windows runner, hook installation or GUI acceptance is implied.
"""
import argparse
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[2]
OLD_MAC = 'f11a23094f431b25ed309fea815cbd97d1cb4d74'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    assert os.uname().sysname == 'Darwin'
    out = args.output.resolve()
    out.relative_to(ROOT / 'build/macos-adaptation')
    out.mkdir(parents=True, exist_ok=False)
    private = out / 'private-fixture'
    private.mkdir(mode=0o700)
    owner = uuid.uuid4().hex
    (private / '.qa-owner').write_text(owner)
    state = {'complete': False, 'scope': __doc__, 'oldMacSource': OLD_MAC,
             'currentSourceBase': subprocess.check_output(
                 ['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
             'currentSourceIncludesUncommittedIntegration': True,
             'commands': [], 'sourceInputs': {}, 'cases': []}
    protected = {}

    def save():
        (out / 'result.json').write_text(json.dumps(state, indent=2) + '\n')

    def run(label, command, cwd=ROOT, expected=0):
        with (out / (label + '.stdout.txt')).open('wb') as stdout, (out / (label + '.stderr.txt')).open('wb') as stderr:
            result = subprocess.run(command, cwd=cwd, stdout=stdout,
                                    stderr=stderr, timeout=300)
        state['commands'].append({'label': label, 'command': command,
                                  'exitCode': result.returncode})
        save()
        print(label, result.returncode, flush=True)
        assert result.returncode == expected, label

    # Reuse the exact upstream scenarios, replacing only their Windows key
    # adapter. These constants contain synthetic values, not user information.
    spec = importlib.util.spec_from_file_location(
        'organization_compatibility_scenarios',
        ROOT / 'scripts/qa/check-organization-compatibility.py')
    scenarios = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(scenarios)
    # Also consume format10 on this platform: inspecting an export alone does
    # not prove that its detached history can be restored and used safely.
    marker = "  stdout.writeln('SCHEMA21_TO22_IDENTITY_AND_OLD_BACKUP_RESTORE_PASSED');"
    assert scenarios.UPGRADE.count(marker) == 1
    scenarios.UPGRADE = scenarios.UPGRADE.replace(marker, r'''
  final modern = await EncryptedInformationRepository.open(
    '$root/format10-restore', keys(root,'format10-restore'));
  final restoredService = InformationService(repository: modern);
  try {
    final contents = await modern.backups.inspect('$root/new.aimbackup',recovery);
    if(contents.formatVersion!=10) throw StateError('Not a format10 restore');
    await modern.backups.restore(contents);
    final o=restoredService.owner;
    if(o.information.isNotEmpty||o.directories.isNotEmpty||o.tags.isNotEmpty)
      throw StateError('Deleted current objects revived');
    if(!o.informationRevisions.any((r)=>r.item.tagIds.isNotEmpty))
      throw StateError('Detached historical references lost');
    await o.restoreRecycled(modern.recycleEntries.single.id);
    final item=o.information.single;
    if(item.directoryId!=null||item.tagIds.isNotEmpty||
       item.fields.single.value!='synthetic content')
      throw StateError('Missing classification recovery changed content');
  } finally {await restoredService.close();await modern.close();}
  stdout.writeln('SCHEMA21_TO22_IDENTITIES_OLD_AND_FORMAT10_RESTORE_PASSED');
''')
    original = "WindowsDatabaseKeyStore keys(String root, String name) => WindowsDatabaseKeyStore('$root/$name/key.dpapi');"
    replacement = '''
class SyntheticKeys implements DatabaseKeyStore {
  SyntheticKeys(this.value);
  final int value;
  @override Future<List<int>?> read() async => List.filled(32, value);
  @override Future<void> create(List<int> key) async => throw StateError('Test key exists');
}
DatabaseKeyStore keys(String root, String name) => SyntheticKeys(name == 'source' ? 158 : 159);
'''
    sources = {'old': out / 'old-source', 'current': out / 'current-source'}
    try:
        archive = subprocess.check_output([
            'git', 'archive', '--format=zip', OLD_MAC,
            'packages/info_core', 'packages/info_storage'], cwd=ROOT)
        with zipfile.ZipFile(io.BytesIO(archive)) as zipped:
            for member in zipped.infolist():
                (sources['old'] / member.filename).resolve().relative_to(sources['old'].resolve())
            zipped.extractall(sources['old'])
        names = subprocess.check_output([
            'git', 'ls-files', '-z', 'packages/info_core', 'packages/info_storage'],
            cwd=ROOT).decode().split('\0')
        for name in sorted(set(filter(None, names))):
            path = ROOT / name
            target = sources['current'] / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
        for label, source in sources.items():
            rows = {}
            for path in source.rglob('*'):
                if not path.is_file():
                    continue
                name = path.relative_to(source).as_posix()
                if label == 'old':
                    committed = subprocess.check_output(
                        ['git', 'show', OLD_MAC + ':' + name], cwd=ROOT)
                    assert path.read_bytes() == committed, name
                rows[name] = digest(path)
                protected[path] = rows[name]
            state['sourceInputs'][label] = rows
            for package in ['info_core', 'info_storage']:
                run(label + '-pub-' + package, [str(ROOT / 'scripts/dev-macos.sh'),
                    'dart', 'pub', 'get', '--enforce-lockfile', '--offline'],
                    source / 'packages' / package)
        checks = [('old-producer', 'old', scenarios.OLD_PRODUCER),
                  ('upgrade', 'current', scenarios.UPGRADE),
                  ('old-reader', 'old', scenarios.OLD_READER)]
        for name, label, code in checks:
            assert code.count(original) == 1
            code = code.replace(original, replacement)
            package = sources[label] / 'packages/info_storage'
            helper = package / ('qa_' + name.replace('-', '_') + '.dart')
            helper.write_text(code)
            run(name + '-format', [str(ROOT / 'scripts/dev-macos.sh'), 'dart',
                'format', helper.name], package)
            (out / (name + '.dart')).write_bytes(helper.read_bytes())
            bundle = out / ('aot-' + name)
            run(name + '-build', [str(ROOT / 'scripts/dev-macos.sh'), 'dart',
                'build', 'cli', '--target', helper.name, '--output', str(bundle)], package)
            binary = bundle / 'bundle/bin' / helper.stem
            before = digest(private / 'source/library.db') if name == 'old-reader' else None
            run(name, [str(binary), str(private)])
            if before is not None:
                assert digest(private / 'source/library.db') == before
            marker = (out / (name + '.stdout.txt')).read_text().strip()
            state['cases'].append({'name': name, 'marker': marker,
                                   'binarySha256': digest(binary)})
            save()
        expected = ['UNCHANGED_OLD_READER_CREATED_SCHEMA21',
                    'SCHEMA21_TO22_IDENTITIES_OLD_AND_FORMAT10_RESTORE_PASSED',
                    'UNCHANGED_OLD_READER_REJECTED_SCHEMA22_AND_FORMAT10']
        assert [case['marker'] for case in state['cases']] == expected
        assert all(digest(path) == value for path, value in protected.items())
        state.update(complete=True, sourceAndLocksUnchanged=True,
                     oldSourceGitObjectsExact=True, realMacSQLCipher=True,
                     systemKeychainUsed=False, oldReaderRefusalDatabaseBytesPreserved=True,
                     oldBackupRestored=True, conditionalBackup10Verified=True,
                     format10RestoredAndRecycledWithMissingClassification=True,
                     historicalReferencesRetained=True,
                     sourceAndRecipientSyntheticKeysDistinct=True)
    except Exception as error:
        state['failure'] = type(error).__name__ + ': ' + str(error)
        raise
    finally:
        if private.exists():
            assert not private.is_symlink() and (private / '.qa-owner').read_text() == owner
            shutil.rmtree(private)
        state['privateFixtureRemoved'] = not private.exists()
        save()
    print(json.dumps({'complete': state['complete'], 'cases': len(state['cases'])}))


if __name__ == '__main__':
    main()
