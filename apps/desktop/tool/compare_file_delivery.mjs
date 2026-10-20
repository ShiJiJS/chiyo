// Compare original Flutter pixels with the frozen Round05 file delivery pages.
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
const root=path.resolve(import.meta.dirname,'../../..');
const evidence=path.join(root,'docs/development/evidence/29-files');
const prep='C:/Project/network_config/info-manage-worktrees/round05-credential-reference-prep/cases';
for(const width of [1440,1280])for(const receiver of ['ssh','aws']){
  const name=`purple-${width}-${receiver}-pending`;
  const qa=path.join(root,'.scratch/file-delivery-compare',name);fs.mkdirSync(qa,{recursive:true});
  fs.copyFileSync(path.join(evidence,'r3',`${name}.png`),path.join(qa,'actual.png'));
  fs.writeFileSync(path.join(qa,'index.html'),'<!doctype html><meta charset="utf-8"><title>Original Flutter capture</title><style>html,body{margin:0;padding:0}img{display:block;max-width:none}</style><img src="actual.png" alt="Unmodified Flutter screenshot at natural size">');
  const result=spawnSync(process.execPath,['C:/Users/Todoki/.agents/skills/oil-ui-pro/scripts/shoot.mjs',path.join(qa,'index.html'),'--size',`${width}x${width===1440?900:800}`,'--compare',path.join(prep,receiver==='ssh'?'use-file':'use-file-env',`page-${width}x${width===1440?900:800}.png`),'--out',path.join(evidence,'compare-r3',name)],{stdio:'inherit'});
  if(result.status!==0)process.exit(result.status??1);
}
