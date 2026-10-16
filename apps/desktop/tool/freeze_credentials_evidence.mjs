// QA provenance only. Never edits, resizes or recompresses a capture/reference.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {execFileSync} from 'node:child_process';
const root=path.resolve(import.meta.dirname,'../../..');
const round=process.argv[2];
if(!/^r\d+$/.test(round??''))throw Error('Pass a capture round.');
const folder=path.join(root,'docs/development/evidence/27-credentials',round);
const output=path.join(folder,'manifest.json');
if(fs.existsSync(output))throw Error('Round is already frozen; use a new round.');
function record(file){
  const bytes=fs.readFileSync(file),stat=fs.statSync(file);
  const png=bytes.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10]));
  return {path:path.resolve(file).replaceAll('\\','/'),modifiedAt:stat.mtime.toISOString(),bytes:stat.size,
    sha256:crypto.createHash('sha256').update(bytes).digest('hex'),
    ...(png?{width:bytes.readUInt32BE(16),height:bytes.readUInt32BE(20)}:{})};
}
const sourceFiles=['apps/desktop/lib/credential_dialogs.dart','apps/desktop/lib/credential_management.dart',
  'apps/desktop/lib/credentials.dart','apps/desktop/lib/prototype_dialog.dart','apps/desktop/tool/capture_credentials_states.dart'];
const actual=fs.readdirSync(folder).filter(f=>f.endsWith('.png')).sort().map(f=>record(path.join(folder,f)));
const prep='C:/Project/network_config/info-manage-worktrees/round05-credential-reference-prep/cases';
const reference=[];
for(const state of ['file','string','expired','rotate','discovery','links','add-file','add-string'])for(const width of[1440,1280]){
  reference.push(record(path.join(prep,`credential-${state}`,`page-${width}x${width===1440?900:800}.png`)));
}
fs.writeFileSync(output,JSON.stringify({round,frozenAt:new Date().toISOString(),baseCommit:execFileSync('git',['rev-parse','HEAD'],{cwd:root,encoding:'utf8'}).trim(),
  description:'Unmodified Flutter captures; ordinary predecessor r4, 200% predecessor r6. Source hashes identify the reviewed working snapshot.',
  sources:sourceFiles.map(f=>record(path.join(root,f))),actual,reference},null,2)+'\n');
process.stdout.write(`Frozen ${actual.length} captures and ${reference.length} reference records.\n`);
