// Capture the unchanged final HTML cascade for the additional D0 states.
import path from 'node:path';
import {spawnSync} from 'node:child_process';
const root=path.resolve(import.meta.dirname,'../../..');
const cases={delete:'delete',organization:'organized',confirmed:'terminal-proposal','organization-noop':'organization-noop','organization-conflict':'organization-conflict','organization-revoked':'organization-revoked','save-failed':'save-failed'};
for(const [name,state] of Object.entries(cases)){
 if(process.argv.length>2&&!process.argv.slice(2).includes(name))continue;
 const steps=name==='save-failed'?['--steps','click .flow-modal .modal-head button; click .topbar nav button:nth-child(3); click .document-actions .primary; click .modal-backdrop:not(.flow-backdrop) .modal-actions .primary; wait 400']:[];
 const result=spawnSync(process.execPath,['C:/Users/Todoki/.agents/skills/oil-ui-pro/scripts/shoot.mjs',`http://127.0.0.1:8797/index.html?theme=purple&page=proposals&state=${state}`,...steps,'--size','1440x900,1280x800','--out',path.join(root,'docs/development/evidence/25-proposals/reference-aux',name)],{stdio:'inherit'});
 if(result.status!==0)process.exit(result.status??1);
}
