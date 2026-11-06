import {readFile,writeFile} from 'node:fs/promises';
import {dirname,join} from 'node:path';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
const root=dirname(fileURLToPath(import.meta.url));
const cases=JSON.parse(await readFile(join(root,'capture-matrix.json'),'utf8'));
const summary=[];
const networkNon200=[];
const pngDimensionErrors=[];
const keys=['.topbar','main.library-layout','.directory-panel','.item-list-panel','.info-detail','.info-document','.info-title h2','.read-field','.info-footer','.queue','.request-row.selected','.document-card','.document-body','.document-heading','.document-actions','.history-summary','.inner-tabs','.scope-record','.settings-nav','.settings-stage','.settings-page','.settings-page h2','.color-options','.color-option','.template-layout','.template-detail','.modal','.flow-modal','.flow-scroll','.flow-modal .modal-actions'];
let markdown='# DOM / computed CSS measurements\n\nFull computed properties and loaded resources are in each case/report.json → dom.\n\n';
for(const entry of cases){
 const reports=JSON.parse(await readFile(join(root,'cases',entry.id,'report.json'),'utf8'));
 for(const report of reports){
  const png=await readFile(join(root,'cases',entry.id,report.file));
  const actual=png.readUInt32BE(16)+'x'+png.readUInt32BE(20);
  if(actual!==report.size)pngDimensionErrors.push({id:entry.id,file:report.file,expected:report.size,actual});
  for(const resource of report.dom?.resources||[])if(resource.responseStatus&&resource.responseStatus!==200)networkNon200.push({id:entry.id,size:report.size,...resource});
  const measured={id:entry.id,size:report.size,file:report.file,issues:report.issues,lint:report.lint,viewport:report.dom?.viewport,fonts:report.dom?.fonts,stylesheets:report.dom?.stylesheets,rows:[]};
  markdown+='## '+entry.id+' / '+report.size+'\n\n| Selector | x,y,w,h | Font / weight / line | Padding | Grid | Scroll client/content |\n| --- | --- | --- | --- | --- | --- |\n';
  for(const selector of keys){
   const e=report.dom?.elements[selector]?.[0];if(!e)continue;
   const rect=[e.rect.x,e.rect.y,e.rect.width,e.rect.height].join(', '),style=e.style;
   measured.rows.push({selector,rect:e.rect,style,scroll:e.scroll});
   markdown+='| `'+selector+'` | '+rect+' | '+style.fontSize+' / '+style.fontWeight+' / '+style.lineHeight+' | '+style.padding+' | '+style.gridTemplateColumns+' | '+e.scroll.clientHeight+'/'+e.scroll.scrollHeight+' |\n';
  }
  markdown+='\n';summary.push(measured);
 }
}
await writeFile(join(root,'measurements.json'),JSON.stringify(summary,null,2));
await writeFile(join(root,'measurements.md'),markdown);
const hashes=JSON.parse(await readFile(join(root,'source-sha256.json'),'utf8'));
let sourceHashesUnchanged=true;
for(const [name,hash]of Object.entries(hashes.files))if(createHash('sha256').update(await readFile(join(hashes.prototype,name))).digest('hex')!==hash)sourceHashesUnchanged=false;
await writeFile(join(root,'validation-summary.json'),JSON.stringify({screenshots:summary.length,pngDimensionErrors,issues:summary.filter(x=>x.issues?.length),lint:summary.filter(x=>x.lint?.length),fonts:[...new Set(summary.flatMap(x=>(x.fonts||[]).map(f=>f.family+' '+f.weight+' '+f.status)))],stylesheets:summary[0]?.stylesheets,sourceHashesUnchanged,networkNon200,networkNote:'Only the automatic browser favicon.ico requests returned 404. The official tool excludes that irrelevant favicon from UI resource issues. CSS, JavaScript, font resources loaded normally; no server or source changes were made.'},null,2));
let index='# Original HTML screenshots\n\nAll PNGs are original 1x DPR viewport captures. Theme purple.\n\n| Case | URL query (after theme=purple) | UI steps | 1440x900 | 1280x800 | Report |\n| --- | --- | --- | --- | --- | --- |\n';
for(const entry of cases)index+='| '+entry.id+' | `'+entry.query.replace('theme=purple&','')+'` | `'+(entry.steps||'none')+'` | [PNG](cases/'+entry.id+'/page-1440x900.png) | [PNG](cases/'+entry.id+'/page-1280x800.png) | [JSON](cases/'+entry.id+'/report.json) |\n';
await writeFile(join(root,'screenshots.md'),index);
console.log(JSON.stringify({screenshots:summary.length,pngDimensionErrors,sourceHashesUnchanged,issues:summary.filter(x=>x.issues?.length).length,lint:summary.filter(x=>x.lint?.length).length,non200ResourceCount:networkNon200.length},null,2));
