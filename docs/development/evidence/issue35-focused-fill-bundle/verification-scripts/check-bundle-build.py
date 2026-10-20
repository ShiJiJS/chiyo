import hashlib,json,re,subprocess
from pathlib import Path
root=Path('C:/Project/network_config/info-manage')
build=root/'apps/desktop/build/windows/x64'
cmake=re.search(r'^CMAKE_COMMAND:INTERNAL=(.+)$',(build/'CMakeCache.txt').read_text(),re.M)[1]
folder=root/'build/qa-issue35/bundle-build-contract'
folder.mkdir(parents=True,exist_ok=True)
script=root/'apps/desktop/windows/focused_input/write_identity.cmake'
helper=folder/'synthetic.exe'
output=folder/'generated'
checks=[]
for contents in [b'abc',b'abc',b'abd']:
    helper.write_bytes(contents)
    header=output/'focused_fill_identity.h'
    old=header.stat().st_mtime_ns if header.exists() else None
    result=subprocess.run([cmake,'-DBROKER='+str(helper),'-DOUTPUT_DIR='+str(output),'-P',str(script)],capture_output=True)
    assert result.returncode==0,result.stderr
    digest=hashlib.sha256(contents).hexdigest()
    assert digest in header.read_text()
    if len(checks)==1: assert header.stat().st_mtime_ns==old
    checks.append({'kind':'generated-identity','digest':digest,'unchangedHeader':len(checks)==1})
result=subprocess.run([cmake,'-DBROKER='+str(folder/'missing.exe'),'-DOUTPUT_DIR='+str(output),'-P',str(script)],capture_output=True)
assert result.returncode!=0
checks.append({'kind':'missing-helper-fails-build','exitCode':result.returncode})
for config in ['Release','Debug']:
    app=build/'runner'/config/'info_desktop.exe'
    helper=app.parent/'info-focus-broker.exe'
    digest=hashlib.sha256(helper.read_bytes()).hexdigest()
    header=build/'focused-input-identity'/config/'focused_fill_identity.h'
    assert digest in header.read_text()
    assert digest.encode() in app.read_bytes()
    assert not any(path.name in ['info-focus-fixture.exe','info-focus-inspector.exe'] or '_stub' in path.name
        for path in app.parent.glob('*.exe'))
    checks.append({'kind':'built-identity','configuration':config,'helperSha256':digest,
        'compiledIntoRunner':True,'onlyProductionHelperShipped':True})
(folder/'result.json').write_text(json.dumps(checks,indent=2)+'\n',encoding='utf-8')
print(json.dumps({'checks':len(checks),'configurations':['Release','Debug']}))
