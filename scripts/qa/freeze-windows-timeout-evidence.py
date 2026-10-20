from pathlib import Path
import hashlib, json, re, shutil, subprocess

root = Path.cwd()
source = '291801046f7d1e6e4217a4bc001ea714689855c5'
folder = root / 'build/windows-preview-round05-2918010'
dest = root / 'docs/development/evidence/windows-timeout-fix'
assert not dest.exists()

def read(name):
    return (root / name).read_text(encoding='utf-8-sig')

def receipt(text):
    result = json.loads(next(line for line in reversed(text.splitlines()) if line.startswith('{')))
    assert result['testExitCode'] == 0 and result['containerRemovedAfterRun'] is True
    return result

package = read('.timeout-package-2918010.log')
assert list(map(int, re.findall(r'\+(\d+): All tests passed!', package))) == [56,130,61,104,11]
assert not re.search(r'\bskipped\b|\bSome tests failed\b|~\d+',package)
native = read('.timeout-fixed-native-unobserved-three.log')
assert list(map(int,re.findall(r'\+(\d+): All tests passed!',native))) == [1,1,1]
assert native.count('D8_NATIVE_VERIFIED') == 3 and 'Some tests failed' not in native
post = read('.timeout-package-native.log')
assert '+1: All tests passed!' in post and 'Some tests failed' not in post
for name in ['.timeout-gui-crash.log','.timeout-package-gui-crash.log']:
    text = read(name)
    facts = json.loads(next(line for line in text.splitlines() if line.startswith('WINDOWS_HOSTED_CRASH_VERIFIED ')).split(' ',1)[1])
    assert len(facts) == 7 and all(v is True for v in facts.values())
    receipt(text)
for text in [package,native,post]: receipt(text)
assert 'Actual: <70>' in read('.timeout-receipt-red.log')
assert 'Actual: <true>' in read('.timeout-protocol-red3.log')
assert 'All tests passed!' in read('.timeout-protocol-green.log')
assert 'SemanticsHandle was active' in read('.timeout-fixed-native-three.log')

manifest_path = folder / 'AgentInfoManage/manifest.json'
manifest = json.loads(manifest_path.read_text(encoding='utf-8-sig'))
assert manifest['sourceCommit'] == source and manifest['sourceDirty'] is False
assert manifest['release'].startswith('0.4.0+8-')
archive = next(folder.glob('*.zip'))
sha = hashlib.sha256(archive.read_bytes()).hexdigest()
assert sha == Path(str(archive)+'.sha256').read_text(encoding='utf-8-sig').split()[0]
assert not subprocess.check_output(['git','diff','f3e3472',source,'--',
    'packages/info_cli/lib','packages/info_core/lib','packages/info_storage/lib',
    'apps/desktop/lib','apps/desktop/windows'],cwd=root).strip()

(dest/'raw').mkdir(parents=True)
files=[]
def copy(original,target):
    raw=original.read_bytes()
    path=dest/'raw'/target
    path.write_bytes(raw)
    assert path.read_bytes()==raw
    files.append({'path':'raw/'+target,'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()})
for log in sorted(root.glob('.timeout-*.log')):
    copy(log,log.name.removeprefix('.'))
copy(root/'docs/development/evidence/30-integration/raw/d8-final-native-three-timeout.log','legacy-native-timeout.log')
copy(manifest_path,'package-manifest-2918010.json')
copy(root/'.scratch/timeout-gui-probe-binaries.json','gui-crash-probe-binaries.json')
copy(root/'.scratch/worker-fast-probe.dart','supplemental-fast-worker-probe.dart.txt')
summary={
    'packageSource':source,'productionFixSource':subprocess.check_output(['git','rev-parse','f3e3472'],text=True).strip(),
    'nativeAotSource':read('.scratch/timeout-aot/source.txt').strip(),
    'release':manifest['release'],'archiveRelativePath':archive.relative_to(root).as_posix(),
    'archiveBytes':archive.stat().st_size,'archiveSha256':sha,'payloadFiles':len(manifest['files']),
    'headlessCounts':{'cli':56,'core':130,'storage':61,'desktop':104},'headlessTotal':351,
    'skipped':0,'extractedSdkFreePasses':11,'nativeFullPasses':3,
    'nativeConfiguredShortRunsPerPass':60,'packagedNativePasses':1,'packagedNativeDefaultShortRuns':10,
    'guiProcessDeathVerificationPasses':2,'guiProcessDeathFactsPerPass':7,
    'configurationEvidence':'HOSTED_SHORT_RUNS=60 in invocation; native source consumes the define. Raw native log records test completion, not individual count lines.',
    'knownLimitations':[
        'Legacy one-off timeout has no stage evidence; cannot uniquely attribute it to reproduced receipt lock.',
        'Actual OS notification click still unverified; both bounded attempts this session failed. Temporary C++ trace draft was not retained and its phase delivery was not verified.',
        'External UIA observation caused a SemanticsHandle end-check failure; preserved and excluded from the three passes.',
        'One old-binary stress pass succeeded, then repetition was interrupted to avoid mixed worker protocols; not three passes.',
        'Actual Codex model installation/trust and clean Windows machine remain manual gates; no model subagents or user config changes.',
        'Server sync paused; Mac and cross-platform restore deferred.'
    ],
    'review':'Main session self-review of implementation and spec; no independent agent review.',
    'files':files,
}
(dest/'verification.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(json.dumps({k:summary[k] for k in ['release','archiveSha256','archiveBytes','headlessTotal','payloadFiles']},ensure_ascii=False))
