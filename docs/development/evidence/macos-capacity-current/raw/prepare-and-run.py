from pathlib import Path
import hashlib,io,json,os,subprocess,tarfile,uuid,zipfile
root=Path.cwd();base=root/'build/macos-adaptation/issue44-capacity-current-20261022';source=base/'source';source.mkdir(exist_ok=False);logs=base/'logs';logs.mkdir()
commit=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip();state={'sourceCommit':commit,'complete':False,'commands':[],'inputSourceHashes':{}}
sha=lambda b:hashlib.sha256(b).hexdigest()
def save():(base/'preparation.json').write_text(json.dumps(state,ensure_ascii=False,indent=2)+'\n')
a=tarfile.open(fileobj=io.BytesIO(subprocess.check_output(['git','archive',commit,'apps/desktop','packages','scripts','integrations','third_party'])))
for item in a.getmembers():
 if item.isdir():continue
 assert item.isfile();data=a.extractfile(item).read();p=source/item.name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data);p.chmod(item.mode);state['inputSourceHashes'][item.name]=sha(data)
for name in ['.tools','.downloads']:(source/name).symlink_to(root/name,target_is_directory=True)
(source/'.cache').mkdir();(source/'.cache/pub').symlink_to(root/'.cache/pub',target_is_directory=True)
config=source/'apps/desktop/macos/Runner/Configs/AppInfo.xcconfig';identity='org.shijijs.agent-info-manage.qa.capacity.'+uuid.uuid4().hex
old='PRODUCT_BUNDLE_IDENTIFIER = com.example.infoDesktop';assert config.read_text().count(old)==1;config.write_text(config.read_text().replace(old,'PRODUCT_BUNDLE_IDENTIFIER = '+identity));state['bundleIdentifier']=identity;state['copyModifications']={str(config.relative_to(source)):sha(config.read_bytes())}
archive=root/'build/macos-adaptation/issue50-package-21/agent-info-manage-0.4.1+13-mac-dev.dd050f3caa1b-macos-arm64.zip';expected='2030d3d50a35d181341ef761b45a6045f52814695a85847417e409738be3058e';assert sha(archive.read_bytes())==expected
with zipfile.ZipFile(archive) as z:
 manifests=[n for n in z.namelist() if n.endswith('/manifest.json') and n.count('/')==1];assert len(manifests)==1,manifests
 n=manifests[0];manifest=json.loads(z.read(n));entry=next(row for row in manifest['files'] if row['path']=='cli/info');data=z.read(n.removesuffix('manifest.json')+'cli/info');assert sha(data)==entry['sha256'];delivery=base/'delivery';(delivery/'cli').mkdir(parents=True);(delivery/'manifest.json').write_text(json.dumps(manifest));(delivery/'cli/info').write_bytes(data);(delivery/'cli/info').chmod(entry['mode'])
state['cliPackageSource']=manifest['sourceCommit'];state['cliPackageZipSha256']=expected;state['cliSha256']=sha(data);save()
def run(label,args,cwd):
 with (logs/(label+'.txt')).open('wb') as f:r=subprocess.run(args,cwd=cwd,stdout=f,stderr=subprocess.STDOUT,timeout=1200)
 state['commands'].append({'label':label,'exitCode':r.returncode});save();print(label,r.returncode,flush=True);assert r.returncode==0,label
launcher=str(source/'scripts/dev-macos.sh')
for pkg in ['info_core','info_cli','info_storage']:run('pub-'+pkg,[launcher,'dart','pub','get','--enforce-lockfile'],source/'packages'/pkg)
run('pub-desktop',[launcher,'flutter','pub','get','--enforce-lockfile'],source/'apps/desktop')
run('analyze',[launcher,'flutter','analyze','--no-pub','--fatal-infos','--fatal-warnings'],source/'apps/desktop')
run('capacity',['python3',str(source/'scripts/qa/macos-file-capacity.py'),str(source/'build/current-capacity'), '--delivery',str(delivery)],source)
state['complete']=True;save()
