// QA only: show untouched Flutter pixels at natural size for oil --compare.
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
const root=path.resolve(import.meta.dirname,'../../..');
const evidence=path.join(root,'docs/development/evidence/25-proposals');
const prep='C:/Project/network_config/info-manage-worktrees/round05-page-reference-prep/cases';
for(const width of [1440,1280])for(const state of ['new','editor','confirm','diff','conflict','delete','organization','confirmed','organization-noop','organization-conflict','organization-revoked','save-failed']){
 const name=`purple-${width}-${state}`, height=width===1440?900:800;
 const qa=path.join(root,'.scratch/proposal-compare',name); fs.mkdirSync(qa,{recursive:true});
 fs.copyFileSync(path.join(evidence,'fidelity',`${name}.png`),path.join(qa,'actual.png'));
 fs.writeFileSync(path.join(qa,'index.html'),'<!doctype html><meta charset="utf-8"><style>html,body{margin:0;padding:0}img{display:block;max-width:none}</style><img src="actual.png">');
 const reference=['new','editor','confirm','diff','conflict'].includes(state)?path.join(prep,`proposal-${state}`,`page-${width}x${height}.png`):path.join(evidence,'reference-aux',state,`page-${width}x${height}.png`);
 const result=spawnSync(process.execPath,['C:/Users/Todoki/.agents/skills/oil-ui-pro/scripts/shoot.mjs',path.join(qa,'index.html'),'--size',`${width}x${height}`,'--compare',reference,'--out',path.join(evidence,process.argv[2]??'compare-r1',name)],{stdio:'inherit'});
 if(result.status!==0)process.exit(result.status??1);
}
