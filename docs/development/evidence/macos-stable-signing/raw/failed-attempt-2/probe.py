from pathlib import Path
import os,subprocess,json,secrets,uuid,hashlib,plistlib,time,shutil
root=Path.cwd();out=Path(__file__).resolve().parent
private=out/('private-'+uuid.uuid4().hex);private.mkdir(mode=0o700)
owner=secrets.token_hex(16);(private/'.qa-owner').write_text(owner)
os.umask(0o077)
password=secrets.token_hex(32)
service='org.shijijs.agent-info-manage.qa.'+str(uuid.uuid4())
facts={'sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'complete':False,'scope':'ephemeral self-signed identities in owned file keychain; actual production DatabaseKeyStore in native signed sandbox Apps; only UUID synthetic Keychain service; no production key/database, no trust-settings change','steps':[],'service':service}
beforeList=subprocess.check_output(['security','list-keychains','-d','user']);beforeDefault=subprocess.check_output(['security','default-keychain','-d','user'])
def sha(b):return hashlib.sha256(b).hexdigest()
facts['keychainContextBefore']={'searchListHash':sha(beforeList),'defaultHash':sha(beforeDefault)}
def save():(out/'result.json').write_text(json.dumps(facts,indent=2)+'\n')
def run(label,args,*,stdin=None,required=True,timeout=30,public=True):
 started=time.monotonic()
 try:
  p=subprocess.run(args,input=stdin,capture_output=True,timeout=timeout)
  code=p.returncode
 except subprocess.TimeoutExpired as e:
  code=124;p=subprocess.CompletedProcess(args,code,e.stdout or b'',e.stderr or b'')
 record={'label':label,'exit':code,'elapsedSeconds':round(time.monotonic()-started,3)}
 if public:
  (out/(label+'.stdout.txt')).write_bytes(p.stdout);(out/(label+'.stderr.txt')).write_bytes(p.stderr)
 facts['steps'].append(record);save();print(label,code,flush=True)
 if required and code:raise RuntimeError(label+' failed; see owned result')
 return p
helper=str(out/'signer-fixture')
def fixture(action):return json.dumps({'action':action,'root':str(private),'owner':owner,'password':password}).encode()
apps={};createdApps=[];keysCreated=False
try:
 for label in ['A','Other']:
  config=private/(label+'.cnf')
  config.write_text('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=codesign\n[dn]\nCN=AgentInfo Synthetic Signing '+label+' '+uuid.uuid4().hex[:16]+'\n[codesign]\nkeyUsage=critical,digitalSignature,keyCertSign\nextendedKeyUsage=critical,codeSigning\nbasicConstraints=critical,CA:true,pathlen:0\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n')
  key=private/(label+'.pem');cert=private/(label+'.crt');p12=private/(label+'.p12')
  run('generate-key-'+label,['openssl','genpkey','-algorithm','RSA','-pkeyopt','rsa_keygen_bits:3072','-aes-256-cbc','-pass','stdin','-out',str(key)],stdin=(password+'\n').encode(),public=False)
  run('generate-certificate-'+label,['openssl','req','-new','-x509','-sha256','-days','2','-key',str(key),'-passin','stdin','-config',str(config),'-out',str(cert)],stdin=(password+'\n').encode(),public=False)
  # Separate password pipes avoid secrets in argv or process environment.
  readIn,writeIn=os.pipe();readOut,writeOut=os.pipe()
  os.write(writeIn,(password+'\n').encode());os.close(writeIn);os.write(writeOut,(password+'\n').encode());os.close(writeOut)
  try:
   p=subprocess.run(['openssl','pkcs12','-export','-inkey',str(key),'-in',str(cert),'-out',str(p12),'-keypbe','PBE-SHA1-3DES','-certpbe','PBE-SHA1-3DES','-macalg','sha1','-passin','fd:'+str(readIn),'-passout','fd:'+str(readOut)],pass_fds=(readIn,readOut),capture_output=True,timeout=30)
   assert p.returncode==0,'export isolated synthetic PKCS12'
  finally:os.close(readIn);os.close(readOut)
  fingerprint=subprocess.check_output(['openssl','x509','-in',str(cert),'-noout','-fingerprint','-sha1'],text=True).strip().split('=')[1].replace(':','')
  facts['certificate'+label]={'sha1':fingerprint,'sha256':sha(cert.read_bytes()),'validDays':2,'syntheticOnly':True}
  key.unlink()
 run('prepare-private-signer',[helper],stdin=fixture('prepare'))
 signingKeychain=private/'signer.keychain'
 original=(root/'scripts/qa/macos-keychain-probe.swift').read_text()
 marker='      case "duplicate":'
 addition='''      case "denied":
        do {
          guard try store.read() == nil else { throw ProbeFailure() }
          print("{\\"deniedByAbsence\\":true}")
        } catch let error as DatabaseKeyFailure {
          guard error.code == "key_unavailable", let status = error.status,
                [errSecAuthFailed, errSecInteractionNotAllowed, errSecNotAvailable].contains(status) else { throw error }
          print("{\\"deniedStatus\\":\\(status)}")
        }
'''
 assert original.count(marker)==1
 (out/'probe.swift').write_text(original.replace(marker,addition+marker))
 identity='org.shijijs.agent-info-manage.qa.stablesigning'
 for label in ['A','B','C','D']:
  app=out/('StableSigner-'+label+'.app');createdApps.append(app);binary=app/'Contents/MacOS/probe';binary.parent.mkdir(parents=True)
  (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':identity if label!='D' else identity+'.other','CFBundleExecutable':'probe','CFBundleName':'Synthetic Stable Signing QA','CFBundlePackageType':'APPL','CFBundleVersion':label}))
  run('compile-'+label,['xcrun','swiftc','-parse-as-library',*(['-D','SECOND_BUILD'] if label!='A' else []),str(root/'apps/desktop/macos/Runner/DatabaseKeyStore.swift'),str(out/'probe.swift'),'-o',str(binary)])
  cert=facts['certificateOther' if label=='C' else 'certificateA']['sha1']
  run('sign-'+label,['codesign','--force','--sign',cert,'--keychain',str(signingKeychain),'--timestamp=none','--entitlements',str(root/'apps/desktop/macos/Runner/Release.entitlements'),str(app)])
  run('verify-'+label,['codesign','--verify','--deep','--strict',str(app)])
  req=run('requirement-'+label,['codesign','-d','-r-',str(app)])
  facts['variant'+label]={'binarySha256':sha(binary.read_bytes()),'designatedRequirement':req.stdout.decode().strip(),'signingCertificate':cert}
  apps[label]=str(binary)
 assert facts['variantA']['binarySha256']!=facts['variantB']['binarySha256']
 assert facts['variantA']['designatedRequirement']==facts['variantB']['designatedRequirement']
 assert facts['variantA']['designatedRequirement']!=facts['variantC']['designatedRequirement']
 assert facts['variantA']['designatedRequirement']!=facts['variantD']['designatedRequirement']
 for step in ['missing','create','read']:
  keysCreated=keysCreated or step=='create'
  run('A-'+step,[apps['A'],service,step])
 run('B-read-after-code-upgrade',[apps['B'],service,'read'])
 run('B-independent-reopen',[apps['B'],service,'read'])
 run('C-different-certificate-denied',[apps['C'],service,'denied'])
 run('D-different-identifier-denied',[apps['D'],service,'denied'])
 run('A-original-still-reads',[apps['A'],service,'read'])
 facts['crossVersionKeyAccessPreserved']=True;facts['unrelatedSignersDenied']=True
 facts['probeCasesPassed']=True
finally:
 if keysCreated:
  run('cleanup-owned-test-item',[apps['A'],service,'delete']);run('verify-owned-test-item-absent',[apps['A'],service,'missing'])
 if (private/'signer.keychain').exists() or (private/'signer.keychain-db').exists():
  run('delete-private-signer',[helper],stdin=fixture('delete'))
 afterList=subprocess.check_output(['security','list-keychains','-d','user']);afterDefault=subprocess.check_output(['security','default-keychain','-d','user'])
 facts['searchListRestored']=beforeList==afterList;facts['defaultKeychainUnchanged']=beforeDefault==afterDefault
 assert facts['searchListRestored'] and facts['defaultKeychainUnchanged']
 shutil.rmtree(private);facts['temporarySigningKeysDeleted']=True
 for app in createdApps:
  subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister','-u',str(app)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  shutil.rmtree(app)
 facts['generatedAppsRemoved']=True;facts['complete']=facts.get('probeCasesPassed',False);save()
