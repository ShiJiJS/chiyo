// This checks the HTML design, not the production Owner/service implementation.
const {chromium}=require('playwright');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const base=process.env.PROTOTYPE_URL||'http://127.0.0.1:8797/round-06-library/index.html';
const out=process.env.PROTOTYPE_EVIDENCE||'build/library-ux/prototype';
const data=fn=>page.evaluate(fn);
let page;
(async()=>{
 fs.mkdirSync(out,{recursive:true});
 const browser=await chromium.launch({channel:'msedge',headless:true});
 const context=await browser.newContext({viewport:{width:1280,height:800}});
 page=await context.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));
 let passed=0;
 async function check(name,fn){await fn();passed++;console.log('PASS '+name);}
 try{
 await page.goto(base);await page.waitForSelector('.tree-row');
 await check('one create form, separated parent, invalid path, retained failed input and retry',async()=>{
  await page.getByRole('button',{name:'新建目录',exact:true}).click();
  await page.locator('#directory-name').fill('工作/运维');await page.getByRole('button',{name:'创建',exact:true}).click();
  await assert.match(await page.locator('.error').innerText(),/单级/);
  await page.locator('#directory-name').fill('新运维');
  await data(()=>Alpine.$data(document.body).failNext=true);
  await page.getByRole('button',{name:'创建',exact:true}).click();
  assert.equal(await page.locator('#directory-name').inputValue(),'新运维');
  assert.match(await page.locator('.error').innerText(),/保存失败/);
  await page.getByRole('button',{name:'创建',exact:true}).click();
  assert.equal(await page.locator('.backdrop').isVisible(),false);
  await page.reload();await page.waitForSelector('.tree-row');
  assert.equal(await data(()=>Alpine.$data(document.body).dirs.filter(d=>d.name==='新运维').length),1);
 });
 await check('move disables self and descendants, nonempty delete blocked',async()=>{
  await data(()=>{const a=Alpine.$data(document.body);a.editDirectory('work',null);});
  assert.equal(await page.getByRole('button',{name:'工作 不可移入'}).isDisabled(),true);
  await page.keyboard.press('Escape');
  await data(()=>{const a=Alpine.$data(document.body);a.editId='work';a.draftName='工作';a.open('delete');});
  assert.equal(await page.getByRole('button',{name:'删除',exact:true}).isDisabled(),true);await page.keyboard.press('Escape');
 });
 await check('filter intersection and clear preserves folder, all resets',async()=>{
  assert.equal(await data(()=>{const a=Alpine.$data(document.body);a.directory='services';a.query='服务';a.tagIds=['document','team'];return a.filtered().length;}),1);
  await page.getByRole('button',{name:'清除筛选',exact:true}).click();
  assert.equal(await data(()=>Alpine.$data(document.body).directory),'services');
  await page.getByRole('button',{name:/^全部信息/}).click();
  assert.equal(await data(()=>Alpine.$data(document.body).directory),null);
 });
 await check('tag creation and delete preserve item identities',async()=>{
  const before=await data(()=>Alpine.$data(document.body).items.map(i=>i.id));
  await data(()=>{const a=Alpine.$data(document.body);a.open('tags');});
  await page.getByRole('button',{name:'新建标签',exact:true}).click();await page.getByRole('textbox',{name:'标签名称',exact:true}).fill('交付');
  await page.getByRole('button',{name:'保存',exact:true}).click();
  await data(()=>{const a=Alpine.$data(document.body);a.pendingTag=a.tags.find(t=>t.id==='team');a.surface='deleteTag';});
  await page.getByRole('button',{name:'删除',exact:true}).click();
  assert.deepEqual(await data(()=>Alpine.$data(document.body).items.map(i=>i.id)),before);
  assert.equal(await data(()=>Alpine.$data(document.body).items.some(i=>i.tags.includes('team'))),false);await page.keyboard.press('Escape');
 });
 await check('organize saves one coherent directory and tag selection',async()=>{
  await data(()=>{const a=Alpine.$data(document.body);a.all();a.selected='docs';a.organize();a.draftParent='personal';a.draftTags=['document'];});
  await page.getByRole('button',{name:'保存',exact:true}).click();
  assert.equal(await data(()=>Alpine.$data(document.body).items.find(i=>i.id==='docs').directory),'personal');
 });
 await check('stress fixture and rendered scroll lanes in four themes and two viewports',async()=>{
  for(const size of [{width:1440,height:900},{width:1280,height:800}])for(const theme of ['purple','green','blue','mono']){
   await page.setViewportSize(size);await page.goto(base+'?state=stress&theme='+theme);await page.waitForSelector('.tree-row');
   assert.deepEqual(await data(()=>{const a=Alpine.$data(document.body);return [a.dirs.length,a.tags.length,a.items.length]}),[56,100,200]);
   assert.equal(await data(()=>document.documentElement.scrollWidth>innerWidth),false);
   const overlap=await page.locator('.tree .more').evaluateAll(nodes=>nodes.some(n=>{const container=n.closest('.tree').getBoundingClientRect();return n.getBoundingClientRect().right>container.right-12;}));assert.equal(overlap,false);
   await page.screenshot({path:out+'/'+theme+'-'+size.width+'.png'});
  }
  await page.goto(base+'?state=stress');await page.evaluate(()=>{const sizes=[...document.querySelectorAll('button,input,p,span,small,h1,h2,h3,label,code,strong')].map(e=>[e,parseFloat(getComputedStyle(e).fontSize)]);for(const [e,size] of sizes)e.style.fontSize=(size*2)+'px';});
  // This is text reflow, distinct from DPR screenshots. Production 200% uses Flutter TextScaler.
  await page.screenshot({path:out+'/stress-text-reflow.png'});
 });
 assert.deepEqual(errors,[]);fs.writeFileSync(out+'/verification.json',JSON.stringify({scope:'HTML prototype only',checks:passed,pageErrors:errors,fixtures:{directories:56,tags:100,information:200},independentReview:false},null,2));
 console.log(passed+' HTML design checks passed');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
