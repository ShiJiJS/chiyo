// QA only: compare unmodified Flutter pixels with the approved HTML reference.
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
const root=path.resolve(import.meta.dirname,'../../..');
const evidence=path.join(root,'docs/development/evidence/27-credentials');
const round=process.argv[2]??'r1';
const prep='C:/Project/network_config/info-manage-worktrees/round05-credential-reference-prep/cases';
const states=process.argv[3]==='links'?['links']:process.argv[3]==='review'?['file','string','expired','rotate','discovery','links','add-file','add-string']
  :process.argv[3]==='aux'?['rotate','discovery','string','expired','links','server']:['file','add-file','add-string'];
for(const width of [1440,1280])for(const state of states){
  const name=`purple-${width}-${state}`;
  const reference=path.join(prep,state==='server'?'server-linked':`credential-${state}`,`page-${width}x${width===1440?900:800}.png`);
  const qa=path.join(root,'.scratch/credential-compare',name);fs.mkdirSync(qa,{recursive:true});
  fs.copyFileSync(path.join(evidence,round,`${name}.png`),path.join(qa,'actual.png'));
  fs.writeFileSync(path.join(qa,'index.html'),'<!doctype html><meta charset="utf-8"><title>Unmodified Flutter capture</title><style>html,body{margin:0;padding:0}img{display:block;max-width:none}</style><img src="actual.png" alt="Unmodified Flutter screenshot at natural size">');
  const result=spawnSync(process.execPath,['C:/Users/Todoki/.agents/skills/oil-ui-pro/scripts/shoot.mjs',path.join(qa,'index.html'),'--size',`${width}x${width===1440?900:800}`,'--compare',reference,'--out',path.join(evidence,`compare-${round}`,name)],{stdio:'inherit'});
  if(result.status!==0)process.exit(result.status??1);
}
