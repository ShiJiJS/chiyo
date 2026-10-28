import {mkdir,writeFile,readFile} from 'node:fs/promises';
import {dirname} from 'node:path';
import {createHash} from 'node:crypto';
export function inspectCredentialForm(){
 const metric=id=>{const i=document.getElementById(id),owner=i.closest('.input-field'),l=owner.querySelector('label'),lr=l.getBoundingClientRect(),ir=i.getBoundingClientRect(),ls=getComputedStyle(l);return{labelHeight:lr.height,gap:ir.top-lr.bottom,inputHeight:ir.height,labelFontSize:parseFloat(ls.fontSize),labelWeight:Number(ls.fontWeight)};};
 const fields={name:metric('core-name'),binding:metric('binding-name')};
 fields.name.nextFieldGap=document.getElementById('core-desc').closest('.input-field').getBoundingClientRect().top-document.getElementById('core-name').getBoundingClientRect().bottom;
 return{viewport:{width:innerWidth,height:innerHeight,dpr:devicePixelRatio},theme:document.body.dataset.theme,selection:ROUND9.state.selected,query:ROUND9.state.query,kind:document.getElementById('core-form').dataset.kind,font:getComputedStyle(document.body).fontFamily,fields};
}
export async function captureCredentialForm(page,{width,height,theme,output}){
 if(![1440,1280].includes(width)||height!==(width===1440?900:800)||!['light','dark'].includes(theme))throw Error('Explicit normal-scale conditions required');
 await mkdir(dirname(output),{recursive:true});
 if(await page.evaluate(()=>!!document.querySelector('.modal-head button[data-action="close"]')))await page.click('.modal-head button[data-action="close"]');
 await page.cdp('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:false});
 await page.click('button[data-page="settings"]');await page.click(`button[data-theme="${theme}"]`);await page.click('button[data-page="library"]');await page.click('button[data-dir="all"]');await page.fill('#search','Azure SSH');await page.click('#record-list [data-item="sshkey"]');
 await page.click('button[aria-label="资料操作"]');await page.click('#menu-root button[data-action="edit"]');await page.waitForSelector('#core-form',{state:'visible'});await page.waitForFunction(()=>document.fonts.status==='loaded'&&!document.getAnimations().some(a=>a.playState==='running'));
 const before=await page.evaluate(inspectCredentialForm);await page.screenshot({path:output+'.png'});const after=await page.evaluate(inspectCredentialForm);const accepted=JSON.stringify(before)===JSON.stringify(after)&&after.viewport.width===width&&after.viewport.height===height&&after.viewport.dpr===1&&after.theme===theme&&after.selection==='sshkey'&&after.query==='Azure SSH'&&after.kind==='credential'&&after.font.includes('Zhiyu System')&&after.font.includes('PingFang SC');
 const result={before,after,accepted,imageSha256:createHash('sha256').update(await readFile(output+'.png')).digest('hex'),fullS5Passed:false,scope:'Only common single-line name/reference control metrics; secure picker and additional Owner metadata mean whole forms differ.'};await writeFile(output+'.json',JSON.stringify(result,null,2)+'\n');if(!accepted)throw Error('Unstable form reference');return result;
}
