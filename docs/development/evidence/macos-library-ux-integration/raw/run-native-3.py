from pathlib import Path
import subprocess,json,shutil,hashlib,os,time

root=Path.cwd();out=Path(__file__).resolve().parent/'native-3';out.mkdir()
source=out/'source';source.mkdir();logs=out/'logs';logs.mkdir()
state={'complete':False,'sourceBase':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'incomingProduct':'9310b1090ecfe5573bbdb34b4d94ea47d0c070ae','workingIntegration':True,'commands':[],'sourceInputs':{},'scope':'Actual macOS Flutter window and SQLCipher; tester pointer/keyboard and registered test IME, ephemeral synthetic key, inert platform; not CUA, physical IME or Keychain'}
def save(): (out/'result.json').write_text(json.dumps(state,indent=2)+'\n')
env=os.environ.copy();env['FLUTTER_MACOS_ARM64_ONLY']='true'
def run(label,args,cwd):
 with (logs/(label+'.txt')).open('wb') as log:
  p=subprocess.Popen(args,cwd=cwd,env=env,stdout=log,stderr=subprocess.STDOUT)
  state['active']={'label':label,'pid':p.pid};save();print(label,p.pid,flush=True)
  try:code=p.wait(timeout=900)
  except subprocess.TimeoutExpired:
   state['timeout']=label;save();raise
 state.pop('active',None);state['commands'].append({'label':label,'exitCode':code,'args':args});save();assert code==0,label
try:
 names=subprocess.check_output(['git','ls-files','-z','apps/desktop','packages','scripts','integrations','third_party']).decode().split('\0')
 for name in sorted(set(filter(None,names))):
  p=root/name;d=source/name;d.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,d);state['sourceInputs'][name]=hashlib.sha256(p.read_bytes()).hexdigest()
 for n in ['.tools','.downloads']:(source/n).symlink_to(root/n,target_is_directory=True)
 (source/'.cache').mkdir();(source/'.cache/pub').symlink_to(root/'.cache/pub',target_is_directory=True)
 config=source/'apps/desktop/macos/Runner/Configs/AppInfo.xcconfig';before=config.read_text();assert before.count('PRODUCT_BUNDLE_IDENTIFIER = com.example.infoDesktop')==1
 config.write_text(before.replace('PRODUCT_BUNDLE_IDENTIFIER = com.example.infoDesktop','PRODUCT_BUNDLE_IDENTIFIER = org.shijijs.agent-info-manage.qa.libraryux20261022'))
 state['qaConfigSha256']=hashlib.sha256(config.read_bytes()).hexdigest();save()
 launcher=str(source/'scripts/dev-macos.sh')
 for package in ['info_core','info_cli','info_storage']:
  run('pub-'+package,[launcher,'dart','pub','get','--enforce-lockfile'],source/'packages'/package)
 desktop=source/'apps/desktop';run('pub-desktop',[launcher,'flutter','pub','get','--enforce-lockfile'],desktop)
 run('analyze',[launcher,'flutter','analyze','--no-pub','--fatal-infos'],desktop)
 run('native-test',[launcher,'flutter','test','--no-pub','-d','macos','integration_test/library_ux_native_test.dart','--reporter','expanded'],desktop)
 run('production-release',[launcher,'build'],source)
 app=desktop/'build/macos/Build/Products/Release/info_desktop.app'
 run('release-signature',['codesign','--verify','--deep','--strict','--verbose=2',str(app)],source)
 state['complete']=True
except Exception as e:
 state['failure']=type(e).__name__+': '+str(e);save();raise
finally:
 save()
print('NATIVE_CLASSIFICATION_COMPLETE',state['complete'],flush=True)
