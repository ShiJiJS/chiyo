import {readFile,writeFile} from 'node:fs/promises';
import {join,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
const root=dirname(fileURLToPath(import.meta.url));
const matrix=JSON.parse(await readFile(join(root,'capture-matrix.json'),'utf8'));
const source=JSON.parse(await readFile(join(root,'source-sha256.json'),'utf8'));
for(const [file,hash] of Object.entries(source.files)) {
 if(createHash('sha256').update(await readFile(join(source.prototype,file))).digest('hex')!==hash)throw Error('source changed: '+file);
}
const summaries=[], measurements={};
for(const entry of matrix) {
 const reports=JSON.parse(await readFile(join(root,'cases',entry.id,'report.json'),'utf8'));
 measurements[entry.id]=reports.map(r=>({file:r.file,viewport:r.dom.viewport,elements:r.dom.elements,theme:r.dom.theme}));
 for(const r of reports) {
  const elements=r.dom.elements;
  summaries.push({case:entry.id,file:r.file,viewport:r.dom.viewport,issues:r.issues,lint:r.lint,heading:(elements['.modal-head h2']??elements['.info-title h2']??elements['.document-heading']??[]).map(x=>x.text),fonts:r.dom.fonts,failedResources:r.dom.resources.filter(x=>x.responseStatus>=400&&!x.name.endsWith('/favicon.ico'))});
 }
}
await writeFile(join(root,'validation-summary.json'),JSON.stringify({count:summaries.length,sourceUnchanged:true,screenshots:summaries},null,2));
await writeFile(join(root,'measurements.json'),JSON.stringify(measurements,null,2));
const lines=['# 凭据与使用流程 HTML 参考图','','全部来自已确认 round05 HTML；紫色，1x DPR，原始内容视口。不是 Flutter 实现或业务验收。','','| Case | Query | Steps | 1440×900 | 1280×800 |','| --- | --- | --- | --- | --- |'];
for(const e of matrix)lines.push(`| ${e.id} | \`${e.query}\` | \`${e.steps||'none'}\` | [PNG](cases/${e.id}/page-1440x900.png) | [PNG](cases/${e.id}/page-1280x800.png) |`);
await writeFile(join(root,'screenshots.md'),lines.join('\n')+'\n');
console.log(JSON.stringify({cases:matrix.length,screenshots:summaries.length,sourceUnchanged:true,issues:summaries.filter(x=>x.issues.length).map(x=>({case:x.case,file:x.file,issues:x.issues})),lint:summaries.filter(x=>x.lint.length).map(x=>({case:x.case,file:x.file,lint:x.lint})),resourceFailures:summaries.filter(x=>x.failedResources.length).length}));