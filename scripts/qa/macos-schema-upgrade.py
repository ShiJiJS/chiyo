#!/usr/bin/env python3
"""Actual pinned schema20 AOT source to current Mac SQLCipher migration.

Synthetic key exists only in parent/child memory and anonymous stdin. No Keychain,
physical UI, signed-app upgrade, Windows or production-data claim.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[2]
LEGACY = 'dbb94ac'
HELPER = ROOT / 'scripts/qa/macos-schema-upgrade-probe.dart'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    out = args.output.resolve(); out.relative_to(ROOT / 'build/macos-adaptation')
    out.mkdir(parents=True, exist_ok=False)
    owner = uuid.uuid4().hex
    fixture = out / 'private-fixture'; fixture.mkdir()
    (fixture / '.qa-owner').write_text(owner)
    key = os.urandom(32)
    state = {'complete': False, 'scope': __doc__, 'commands': [], 'cases': [], 'sources': []}
    protected = {}
    source_commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    legacy_commit = subprocess.check_output(['git', 'rev-parse', LEGACY], cwd=ROOT, text=True).strip()
    state.update(sourceCommit=source_commit, legacyCommit=legacy_commit,
                 helperSha256=hashlib.sha256(HELPER.read_bytes()).hexdigest())
    def save(): (out/'result.json').write_text(json.dumps(state, indent=2)+'\n')
    def run(label, command, cwd=ROOT, stdin=None, expected=0):
        result = subprocess.run(command, cwd=cwd, input=stdin, capture_output=True, timeout=300)
        (out/(label+'.stdout.txt')).write_bytes(result.stdout)
        (out/(label+'.stderr.txt')).write_bytes(result.stderr)
        state['commands'].append({'label':label, 'command':command, 'exitCode':result.returncode})
        save(); print(label, result.returncode, flush=True)
        assert result.returncode == expected, label
        return result
    try:
        binaries = []
        for label, commit in [('legacy', legacy_commit), ('current', source_commit)]:
            source = out/(label+'-source'); source.mkdir()
            archive = out/(label+'.zip')
            run(label+'-archive', ['git','archive','--format=zip','--output',str(archive),commit,
                                  'packages/info_core','packages/info_storage'])
            with zipfile.ZipFile(archive) as z:
                for entry in z.infolist(): (source/entry.filename).resolve().relative_to(source)
                z.extractall(source)
            rows = []
            for name in subprocess.check_output(['git','ls-tree','-r','--name-only',commit,'--',
                     'packages/info_core/lib','packages/info_storage/lib',
                     'packages/info_core/pubspec.yaml','packages/info_storage/pubspec.yaml',
                     'packages/info_core/pubspec.lock','packages/info_storage/pubspec.lock'],cwd=ROOT,text=True).splitlines():
                data = subprocess.check_output(['git','show',commit+':'+name],cwd=ROOT)
                path = source/name; assert path.read_bytes()==data
                digest=hashlib.sha256(data).hexdigest();protected[path]=digest
                rows.append({'path':name,'sha256':digest})
            package=source/'packages/info_storage';shutil.copyfile(HELPER,package/HELPER.name)
            state['sources'].append({'label':label,'commit':commit,'verifiedProductionFiles':rows})
            launcher=str(ROOT/'scripts/dev-macos.sh')
            run(label+'-dependencies',[launcher,'dart','pub','get','--enforce-lockfile','--offline'],package)
            run(label+'-analyze',[launcher,'dart','analyze',HELPER.name,'--fatal-infos'],package)
            bundle=out/(label+'-aot')
            run(label+'-aot',[launcher,'dart','build','cli','--target',HELPER.name,'--output',str(bundle)],package)
            binary=bundle/'bundle/bin'/HELPER.stem;assert binary.is_file()
            binaries.append(binary)
            state['sources'][-1]['binarySha256']=hashlib.sha256(binary.read_bytes()).hexdigest()
        def probe(binary,label,mode='inspect',wrong=False,expected=0):
            payload=json.dumps({'key':base64.b64encode(os.urandom(32) if wrong else key).decode()}).encode()
            r=run(label,[str(binary),mode,str(fixture)],stdin=payload,expected=expected)
            result=json.loads(r.stdout);state['cases'].append({'label':label,**result});save();return result
        old,new=binaries
        original=probe(old,'old-schema20-create','create');assert original['schema']==original['marker']==20
        db=fixture/'library/library.db'
        before=hashlib.sha256(db.read_bytes()).hexdigest()
        closed=probe(old,'old-raw-snapshot','snapshot')
        assert closed['tables']==original['tables'] and closed['schema']==20
        assert hashlib.sha256(db.read_bytes()).hexdigest()==before
        wrong=probe(new,'wrong-key-refused',wrong=True,expected=1)
        assert wrong['status']=='failed' and wrong['storageFailure']=='library_unavailable'
        assert hashlib.sha256(db.read_bytes()).hexdigest()==before
        conflict=probe(old,'controlled-registry-conflict','conflict')
        before=hashlib.sha256(db.read_bytes()).hexdigest()
        refused=probe(new,'conflicting-migration-refused',expected=1)
        assert refused['storageFailure']=='unsupported_schema' and hashlib.sha256(db.read_bytes()).hexdigest()==before
        repaired=probe(old,'remove-only-owned-conflict','repair')
        assert repaired['schema']==20 and repaired['tables']==original['tables']
        migrated=probe(new,'same-target-migration-retry')
        assert migrated['schema']==migrated['marker']==21 and migrated['integrity']=='ok'
        tables=migrated['beforeVerificationOperations']['tables']
        # Draft idempotency receipts are session-local owner form state; open
        # deliberately clears them together with orphan stages. All durable
        # content, attachment BLOBs and history rows must remain byte exact.
        assert original['tables']['information_draft_commits']['rows']==2
        assert tables['information_draft_commits']['rows']==0
        assert all(tables[name]==fact for name,fact in original['tables'].items()
                   if name != 'information_draft_commits')
        assert tables['information_deliveries']['rows']==0
        before=hashlib.sha256(db.read_bytes()).hexdigest()
        closed=probe(new,'migrated-raw-snapshot','snapshot')
        assert closed['tables']==migrated['tables'] and closed['schema']==21
        assert hashlib.sha256(db.read_bytes()).hexdigest()==before
        refused=probe(old,'old-reader-refuses-new-schema',expected=1)
        assert refused['storageFailure']=='unsupported_schema' and hashlib.sha256(db.read_bytes()).hexdigest()==before
        reopened=probe(new,'current-reader-reopens');assert reopened['schema']==21 and reopened['integrity']=='ok'
        assert migrated['oldAuthorityRefused'] and reopened['oldAuthorityRefused']
        assert all(hashlib.sha256(p.read_bytes()).hexdigest()==digest for p,digest in protected.items())
        assert (fixture/'.qa-owner').read_text()==owner and not fixture.is_symlink()
        shutil.rmtree(fixture)
        state.update(complete=True,fixtureRemoved=True,productionSourceAndLocksUnchanged=True,
                     allDurableLegacyRowsPreservedBeforeVerification=True,
                     transientDraftReceiptsClearedAsDesigned=True,wrongKeyDatabaseBytesPreserved=True,
                     failedMigrationDatabaseBytesPreserved=True,oldReaderRefusalBytesPreserved=True)
    finally:
        save()
    print(json.dumps({'complete':state['complete'],'cases':len(state['cases'])}))

if __name__=='__main__': main()
