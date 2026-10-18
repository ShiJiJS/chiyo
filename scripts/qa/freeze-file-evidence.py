"""Freeze synthetic QA logs byte-for-byte; never rewrite failures into passes."""
from pathlib import Path
import hashlib,json,re,shutil,subprocess

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'docs/development/evidence/29-files'

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def git(*args):return subprocess.check_output(['git',*args],cwd=ROOT,text=True).strip()

def main():
    source=(ROOT/'.scratch/d7-aot/source.txt').read_text(encoding='utf-8-sig').strip()
    assert source.startswith('2dab838')
    production=['packages/info_core/lib','packages/info_cli/lib','packages/info_cli/bin','packages/info_storage/lib','apps/desktop/lib','apps/desktop/windows/runner']
    assert not git('diff',source,'HEAD','--',*production),'Production changed after the frozen runs'
    runs={'core':('.d7-final2-core.log',125),'cli':('.d7-final2-cli.log',43),'storage':('.d7-final3-storage.log',56),'desktop':('.d7-final2-desktop.log',101)}
    for name,(filename,count) in runs.items():
        text=(ROOT/filename).read_text(encoding='utf-8')
        assert re.search(rf'\+{count}: All tests passed!',text),(name,count)
        assert not re.search(r'\[E\]|~\d+|Some tests failed',text),name
    native=(ROOT/'.d7-final2-native.log').read_text(encoding='utf-8')
    assert native.count('D7_NATIVE_VERIFIED')==3 and native.count('All tests passed!')==3
    assert 'containerRemovedAfterRun": true' in native and 'Some tests failed' not in native
    raw=OUT/'raw';raw.mkdir(parents=True,exist_ok=True)
    names=list(filename for filename,_ in runs.values())+[
      '.d7-final2-native.log','.d7-final2-cli-compile.log','.d7-final2-worker-compile.log',
      '.d7-final2-storage.log','.d7-frozen-storage.log','.d7-file-cli-crash.log',
      '.d7-file-policy-review.log','.d7-repeated-file-red.log','.d7-repeated-file-green.log',
      '.d7-host-backup-gate-red.log','.d7-host-backup-gate-green.log',
      '.d7-closed-host-red.log','.d7-closed-host-green.log','.d7-file-capture-r3.log',
      '.d7-file-compare-r3.log','.d7-ssh-ui-native-r1.log','.d7-ssh-ui-native-r2.log',
      '.d7-cli-full-all-enabled.log','.d7-cli-full-all-enabled-r2.log',
      '.d7-windows-build.log','.d7-aws-real.log','.d7-material-failures.log',
      '.d7-registration-audit-red.log','.d7-job-recovery-green.log',
    ]
    # The original job log has this historical name in this checkout.
    names=[name for name in names if (ROOT/name).exists()]
    copies={}
    for name in names:
        target=raw/name.removeprefix('.')
        if target.exists():assert target.read_bytes()==(ROOT/name).read_bytes(),'Refusing to replace frozen raw evidence'
        else:shutil.copyfile(ROOT/name,target)
        copies[target.relative_to(OUT).as_posix()]={'sha256':sha(target),'bytes':target.stat().st_size}
    images=sorted((OUT/'r3').glob('*.png'));assert len(images)==60
    visual={p.relative_to(OUT).as_posix():sha(p) for p in [*images,*sorted((OUT/'compare-r3').rglob('*.png'))]}
    result={'productionSource':source,'verificationSource':git('rev-parse','HEAD'),'visualSource':git('rev-parse','83579ed'),
      'headless':{'passed':sum(c for _,c in runs.values()),'skipped':0,'packages':{n:{'passed':c,'log':'raw/'+f.removeprefix('.')} for n,(f,c) in runs.items()},'storageFixtureNote':'Bounded complete-counter observation fixed a truncate/read race; the original failed full run is preserved.'},
      'native':{'platform':'Windows','repetitions':3,'sshCasesPerRepetition':4,'exitCodes':[0,255,255,255],'compiledCli':True,'realOpenSsh':True,'sqlCipherDpapiReopen':True,'realAccountCredentials':False},
      'visual':{'screenshots':60,'comparisonPairs':4,'themes':['purple','green','blue','mono'],'viewports':[[1440,900],[1280,800]],'textScale200':True,'independentReview':False,'review':'Main-agent self-check only; user prohibits subagents. Original Round05 file/file-env layout compared, synthetic content differs.'},
      'artifacts':{p.name:sha(p) for p in sorted((ROOT/'.scratch/d7-aot').glob('*.exe'))},
      'computerUse':False,'scope':{'serverSync':'paused by user','macOS':'deferred','codexRealInstallTrust':'not verified','cleanWindowsRelease':'not verified','credentialBackupFormat5':'pending issue31'},
      'raw':copies,'images':visual}
    (OUT/'verification.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8',newline='\n')
    print(json.dumps({'headless':result['headless']['passed'],'nativeRepetitions':3,'screenshots':60,'rawLogs':len(copies),'productionSource':source},ensure_ascii=False))

if __name__=='__main__':main()
