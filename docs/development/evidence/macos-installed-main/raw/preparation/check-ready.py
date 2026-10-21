import json,pathlib,os,time,socket,subprocess,hashlib
out=pathlib.Path(__file__).resolve().parent
started=json.loads((out/'process.json').read_text());pid=started['pid'];app=pathlib.Path(started['app']);root=app.parent.parent
expected=json.loads((root/'manifest.json').read_text())
deadline=time.monotonic()+1800
while True:
 try:os.kill(pid,0)
 except ProcessLookupError:raise RuntimeError('Original ordinary app exited before ready; inspect exit.json')
 with socket.socket() as s:
  s.settimeout(.2);ready=s.connect_ex(('127.0.0.1',47125))==0
 if ready:break
 if time.monotonic()>deadline:raise TimeoutError('Owner Keychain action not completed in readiness observation window')
 time.sleep(.5)
env={'PATH':'/usr/bin:/bin'}
r=subprocess.run([str(root/'cli/info')],input=b'{"command":"capabilities"}\n',capture_output=True,cwd=root,env=env,timeout=15)
(out/'installed-capabilities.stdout.txt').write_bytes(r.stdout);(out/'installed-capabilities.stderr.txt').write_bytes(r.stderr)
assert r.returncode==0
caps=json.loads(r.stdout);assert caps['status']=='ok',caps
loaded=subprocess.check_output(['/usr/sbin/lsof','-p',str(pid),'-Fn'],text=True)
cipher=app/'Contents/Frameworks/sqlcipher.framework/Versions/A/sqlcipher'
assert str(cipher) in loaded and hashlib.sha256(cipher.read_bytes()).hexdigest()==expected['sqlcipher']['desktopSha256']
(out/'actual-loaded-frameworks.txt').write_text('\n'.join(s for s in loaded.splitlines() if '/Contents/Frameworks/' in s and any(x in s for x in ['FlutterMacOS','App.framework','sqlcipher.framework']))+'\n')
facts={'ordinaryAppReachedService':True,'pid':pid,'packagedCliExitCode':r.returncode,'packagedCliPATH':env['PATH'],'actualMappedSQLCipherMatchesManifest':True,'scope':'ordinary fixed package main.dart startup and public packaged CLI capabilities; no approval or GUI workflow assertion'}
(out/'main-ready.json').write_text(json.dumps(facts,indent=2)+'\n');print(json.dumps(facts),flush=True)
