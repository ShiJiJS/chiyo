import {mkdir, readFile, writeFile} from 'node:fs/promises';
import {dirname, isAbsolute} from 'node:path';
import {createHash} from 'node:crypto';

export function inspectContentReading() {
  const rect=e=>{const r=e.getBoundingClientRect();return{x:r.x,y:r.y,width:r.width,height:r.height};};
  const boxes={'detail-title':rect(document.querySelector('.detail-header h1'))};
  const selected=ROUND9.state.selected;
  if(selected==='profile'){
    for(const [key,label] of Object.entries({name:'姓名',email:'联系邮箱',direction:'求职方向',city:'所在城市'})){
      const e=[...document.querySelectorAll('.fact label')].find(e=>e.textContent===label);
      boxes[`field-${key}-label`]=rect(e);boxes[`field-${key}-value`]=rect(e.nextElementSibling);
    }
    for(const [key,title] of Object.entries({education:'教育经历',experience:'工作经历'})){
      const heading=[...document.querySelectorAll('.content-section h2')].find(e=>e.textContent===title);
      boxes[`section-${key}`]=rect(heading);
      for(const [i,entry]of[...heading.parentElement.querySelectorAll('.timeline-entry')].entries()){
        boxes[`${key}-${i}`]=rect(entry);
        for(const [part,selector] of Object.entries({period:'time',title:'h3',detail:'p'})) boxes[`${key}-${i}-${part}`]=rect(entry.querySelector(selector));
        const e=rect(entry),s=getComputedStyle(entry,'::before');
        boxes[`${key}-${i}-dot`]={x:e.x+parseFloat(s.left),y:e.y+parseFloat(s.top),width:parseFloat(s.width),height:parseFloat(s.height)};
      }
    }
  }else{
    boxes.document=rect(document.querySelector('.reading'));
    [...document.querySelectorAll('.reading>h2')].forEach((e,i)=>boxes[`document-heading-${i}`]=rect(e));
    [...document.querySelectorAll('.reading>p')].forEach((e,i)=>boxes[`document-paragraph-${i}`]=rect(e));
    const table=document.querySelector('.reading>table');
    boxes['document-table']=rect(table);
    [...table.rows].forEach((row,r)=>[...row.cells].forEach((cell,c)=>boxes[`document-table-cell-${r}-${c}`]=rect(cell)));
    boxes['document-code']=rect(document.querySelector('.reading>pre'));
    boxes['document-list']=rect(document.querySelector('.reading>ol'));
    [...document.querySelectorAll('.reading>ol>li')].forEach((e,i)=>boxes[`document-list-item-${i}`]=rect(e));
  }
  return{viewport:{width:innerWidth,height:innerHeight,dpr:devicePixelRatio},theme:document.body.dataset.theme,font:getComputedStyle(document.body).fontFamily,selection:selected,query:ROUND9.state.query,scrollbarWidth:document.querySelector('#detail-scroll').offsetWidth-document.querySelector('#detail-scroll').clientWidth,scrollTop:document.querySelector('#detail-scroll').scrollTop,boxes};
}

export async function captureContentReading(page,{width,height,theme,state,output}){
  if(![1440,1280].includes(width)||height!==(width===1440?900:800)||!['light','dark'].includes(theme)||!['R05-top','R05-timeline','R06-document'].includes(state)||!isAbsolute(output))throw new Error('Explicit content capture conditions required');
  await mkdir(dirname(output),{recursive:true});
  await page.cdp('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:false});
  await page.click('button[data-page="settings"]');await page.click(`button[data-theme="${theme}"]`);await page.click('button[data-page="library"]');await page.click('button[data-dir="all"]');
  const selected=state==='R06-document'?'https':'profile';
  await page.fill('input#search',selected==='profile'?'个人档案':'HTTPS');await page.click(`#record-list [data-item="${selected}"]`);
  await page.waitForSelector('#toast-root .toast',{state:'hidden'});await page.waitForFunction(()=>document.fonts.status==='loaded'&&!document.getAnimations().some(a=>a.playState==='running'));
  await page.evaluate(top=>{document.querySelector('#detail-scroll').scrollTop=top;},state==='R05-timeline'?300:0);
  const before=await page.evaluate(inspectContentReading);await page.screenshot({path:output+'.png'});const after=await page.evaluate(inspectContentReading);
  const errors=[];
  if(JSON.stringify(before)!==JSON.stringify(after))errors.push('capture_state_changed');
  if(JSON.stringify(after.viewport)!==JSON.stringify({width,height,dpr:1}))errors.push('viewport');
  if(after.theme!==theme||after.selection!==selected||after.scrollTop!==(state==='R05-timeline'?300:0))errors.push('state');
  if(!after.font.includes('Zhiyu System')||!after.font.includes('PingFang SC'))errors.push('font');
  const report={before,after,accepted:!errors.length,errors,imageSha256:createHash('sha256').update(await readFile(output+'.png')).digest('hex'),fullS5Passed:false,scope:'Capture integrity only; scrollbar policy must match before a qualified geometry comparison; no OS-input or complete motion claim'};
  await writeFile(output+'.json',JSON.stringify(report,null,2)+'\n');if(errors.length)throw new Error('Content reference rejected '+errors.join(','));return report;
}
