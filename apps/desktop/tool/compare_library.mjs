// QA only: render each unmodified Flutter PNG at its natural pixel size, then
// run oil-ui-pro --compare against the canonical HTML PNG. Production is Dart.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
const root=path.resolve(import.meta.dirname,'../../..');
const evidence=path.join(root,'docs/development/evidence/24-library');
const skill='C:/Users/Todoki/.agents/skills/oil-ui-pro/scripts/shoot.mjs';
const prep='C:/Project/network_config/info-manage-worktrees/round05-page-reference-prep/cases';
const outputName=process.argv[2]??'compare';
for(const width of [1440,1280])for(const state of ['default','editor','taxonomy','empty']){
  const name=`purple-${width}${state==='default'?'':`-${state}`}`;
  const actual=path.join(evidence,'fidelity',`${name}.png`);
  const reference=state==='default'?path.join(root,`docs/design/prototype-reference/library-default-purple-${width}.png`):path.join(prep,`library-${state==='empty'?'no-results':state}`,`page-${width}x${width===1440?900:800}.png`);
  const qa=path.join(root,'.scratch/library-compare',name);fs.mkdirSync(qa,{recursive:true});
  fs.copyFileSync(actual,path.join(qa,'actual.png'));
  fs.writeFileSync(path.join(qa,'index.html'),'<!doctype html><meta charset="utf-8"><title>Unmodified Flutter capture</title><style>html,body{margin:0;padding:0}img{display:block;max-width:none}</style><img src="actual.png" alt="Unmodified Flutter screenshot at natural size">');
  const result=spawnSync(process.execPath,[skill,path.join(qa,'index.html'),'--size',`${width}x${width===1440?900:800}`,'--compare',reference,'--out',path.join(evidence,outputName,name)],{stdio:'inherit'});
  if(result.status!==0)process.exit(result.status??1);
}
