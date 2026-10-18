// QA: compare original Flutter pixels with the frozen Round05 HTML captures.
import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';
const root=path.resolve(import.meta.dirname,'../../..');
const evidence=path.join(root,'docs/development/evidence/30-integration');
const frozen=path.join(evidence,'reference-history');
const manifestFile=path.join(frozen,'sources.json');
const digest=bytes=>createHash('sha256').update(bytes).digest('hex');
const canonical=(file,bytes)=>/\.(html|css|js)$/.test(file)?Buffer.from(bytes.toString('utf8').replace(/\r\n/g,'\n')):bytes;
const cases=[['purple-1440-ssh_identity-start-failed','execution-start-failed'],['purple-1440-start-failed','execution-token']];
if(!fs.existsSync(manifestFile)){
  const prep='C:/Project/network_config/info-manage-worktrees/round05-credential-reference-prep';
  const archived=JSON.parse(fs.readFileSync(path.join(prep,'source-sha256.json'),'utf8'));
  const sources={};
  for(const [file,expected] of Object.entries(archived.files)){
    const original=fs.readFileSync(path.join(archived.prototype,file));
    const current=fs.readFileSync(path.join(root,'docs/design/prototypes/round-05',file));
    if(digest(original)!==expected||digest(canonical(file,current))!==digest(canonical(file,original)))throw new Error(`Frozen source differs: ${file}`);
    sources[file]={originalSha256:expected,canonicalSha256:digest(canonical(file,original)),normalization:/\.(html|css|js)$/.test(file)?'CRLF to LF only':'none'};
  }
  fs.mkdirSync(frozen,{recursive:true});
  const references={};
  for(const [,reference] of cases){
    const original=fs.readFileSync(path.join(prep,'cases',reference,'page-1440x900.png'));
    const sourceReport=JSON.parse(fs.readFileSync(path.join(prep,'cases',reference,'report.json'),'utf8'));
    if(sourceReport.some(item=>item.issues?.length))throw new Error('Invalid original capture');
    fs.writeFileSync(path.join(frozen,`${reference}.png`),original);
    references[reference]={sha256:digest(original),size:'1440x900',originalIssues:[]};
  }
  fs.writeFileSync(manifestFile,JSON.stringify({origin:'Existing 2026-10-17 Round05 captures; verified original bytes and current source equality except code EOL',sources,references},null,2)+'\n');
}
const manifest=JSON.parse(fs.readFileSync(manifestFile,'utf8'));
for(const [file,source] of Object.entries(manifest.sources)){
  const current=fs.readFileSync(path.join(root,'docs/design/prototypes/round-05',file));
  if(digest(canonical(file,current))!==source.canonicalSha256)throw new Error(`Frozen source differs: ${file}`);
}
for(const [actual,reference] of cases){
  const referenceFile=path.join(frozen,`${reference}.png`);
  if(digest(fs.readFileSync(referenceFile))!==manifest.references[reference].sha256)throw new Error('Reference pixels changed');
  const qa=path.join(root,'.scratch/d8-history-compare',actual);fs.mkdirSync(qa,{recursive:true});
  fs.copyFileSync(path.join(evidence,'history-r4',`${actual}.png`),path.join(qa,'actual.png'));
  fs.writeFileSync(path.join(qa,'index.html'),'<!doctype html><meta charset="utf-8"><title>Unmodified Flutter history capture</title><style>html,body{margin:0;padding:0}img{display:block;max-width:none}</style><img src="actual.png" alt="Original Flutter pixels">');
  const result=spawnSync(process.execPath,['C:/Users/Todoki/.agents/skills/oil-ui-pro/scripts/shoot.mjs',path.join(qa,'index.html'),'--size','1440x900','--compare',referenceFile,'--out',path.join(evidence,'compare-history-r4',actual)],{stdio:'inherit'});
  if(result.status!==0)process.exit(result.status??1);
}
