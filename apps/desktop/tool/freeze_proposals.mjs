import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {execFileSync} from 'node:child_process';
const root=path.resolve(import.meta.dirname,'../../..');
const evidence=path.join(root,'docs/development/evidence/25-proposals');
const destination=path.join(evidence,process.argv[2]??'review-round2');
if(fs.existsSync(destination))throw new Error('A review round is immutable; choose a new directory.');
fs.mkdirSync(destination,{recursive:true});
const sha=file=>crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const files=[];
for(const name of fs.readdirSync(path.join(evidence,'fidelity')).filter(name=>name.endsWith('.png'))){
 const source=path.join(evidence,'fidelity',name);fs.copyFileSync(source,path.join(destination,name));files.push({file:name,sha256:sha(source),role:'Flutter'});
}
for(const width of [1440,1280])for(const state of ['new','editor','confirm','diff','conflict']){
 const source=`C:/Project/network_config/info-manage-worktrees/round05-page-reference-prep/cases/proposal-${state}/page-${width}x${width===1440?900:800}.png`;
 const name=`reference-purple-${width}-${state}.png`;fs.copyFileSync(source,path.join(destination,name));files.push({file:name,sha256:sha(source),role:'HTML',source});
}
for(const state of fs.readdirSync(path.join(evidence,'reference-aux'))){
 for(const width of [1440,1280]){
  const source=path.join(evidence,'reference-aux',state,`page-${width}x${width===1440?900:800}.png`);
  if(!fs.existsSync(source))continue;
  const name=`reference-purple-${width}-${state}.png`;fs.copyFileSync(source,path.join(destination,name));files.push({file:name,sha256:sha(source),role:'HTML',source});
 }
}
const sources=['apps/desktop/lib/proposal_workspace.dart','apps/desktop/lib/proposal_queue.dart','apps/desktop/lib/information_editor.dart','apps/desktop/lib/prototype_dialog.dart','apps/desktop/tool/capture_proposals.dart','packages/info_core/lib/proposal_access.dart'];
fs.writeFileSync(path.join(destination,'manifest.json'),JSON.stringify({base:execFileSync('git',['rev-parse','HEAD'],{cwd:root,encoding:'utf8'}).trim(),sources:sources.map(file=>({file,sha256:sha(path.join(root,file))})),files,limits:'Static screenshots only. Opaque proposal IDs and missing legacy update/delete self-description are real model differences; never fabricate identity or Agent attribution. 200% and long-batch captures are readability boundaries, not baseline substitution.'},null,2)+'\n');
console.log(`${destination}: ${files.length} images frozen`);
