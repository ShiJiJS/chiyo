import {mkdir,writeFile,readFile} from 'node:fs/promises';
import {dirname} from 'node:path';
import {createHash} from 'node:crypto';
export function inspectAttachmentReading(){
 const rect=e=>{const r=e.getBoundingClientRect();return{x:r.x,y:r.y,width:r.width,height:r.height};};
 const boxes={'detail-title':rect(document.querySelector('.detail-header h1'))};
 if(ROUND9.state.selected==='sshkey'){
  for(const [key,selector]of Object.entries({'credential-summary':'.credential-summary','credential-icon':'.credential-summary>.icon','credential-format':'.credential-summary p','credential-status':'.credential-summary .pill'})) boxes[key]=rect(document.querySelector(selector));
 }else boxes['file-stage']=rect(document.querySelector('.file-stage'));
 return{viewport:{width:innerWidth,height:innerHeight,dpr:devicePixelRatio},theme:document.body.dataset.theme,selection:ROUND9.state.selected,query:ROUND9.state.query,scrollTop:document.querySelector('#detail-scroll').scrollTop,scrollbarWidth:document.querySelector('#detail-scroll').offsetWidth-document.querySelector('#detail-scroll').clientWidth,font:getComputedStyle(document.body).fontFamily,boxes};
}
export async function captureAttachmentReading(page,{width,height,theme,state,output}){
 if(![1440,1280].includes(width)||height!==(width===1440?900:800)||!['light','dark'].includes(theme)||!['resume','sshkey'].includes(state))throw Error('Explicit conditions required');
 await mkdir(dirname(output),{recursive:true});await page.cdp('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:false});
 await page.click('button[data-page="settings"]');await page.click(`button[data-theme="${theme}"]`);await page.click('button[data-page="library"]');await page.click('button[data-dir="all"]');await page.fill('input#search',state==='resume'?'服务端开发简历':'Azure SSH');await page.click(`#record-list [data-item="${state}"]`);
 await page.waitForFunction(()=>document.fonts.status==='loaded'&&!document.getAnimations().some(a=>a.playState==='running'));await page.evaluate(()=>document.querySelector('#detail-scroll').scrollTop=0);const before=await page.evaluate(inspectAttachmentReading);await page.screenshot({path:output+'.png'});const after=await page.evaluate(inspectAttachmentReading);
 const accepted=JSON.stringify(before)===JSON.stringify(after)&&after.viewport.width===width&&after.viewport.height===height&&after.viewport.dpr===1&&after.theme===theme&&after.selection===state&&after.scrollTop===0&&after.font.includes('Zhiyu System')&&after.font.includes('PingFang SC');
 const result={before,after,accepted,fullS5Passed:false,imageSha256:createHash('sha256').update(await readFile(output+'.png')).digest('hex'),scope:'Capture integrity. Real file bytes/page height and required extra actions are separate from fictional HTML paper.'};await writeFile(output+'.json',JSON.stringify(result,null,2)+'\n');if(!accepted)throw Error('Unstable attachment reference');return result;
}
