(function(){
'use strict';
paths.plugin='M9 3h6v5h5v6h-5v7H9v-7H3V8h6V3Z';paths.globe='M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0ZM2 12h20M12 2c-5 5-5 15 0 20m0-20c5 5 5 15 0 20';paths.download='M12 3v12m-5-5 5 5 5-5M4 16v5h16v-5';
const KEY='agent-info-prototype-round09-v1',clone=MODEL.clone;
const initial=()=>({items:clone(MODEL.items),plugins:clone(MODEL.presets),dirs:clone(MODEL.dirs),decisions:{},tags:clone(MODEL.tags),settings:clone(MODEL.settings),proposals:clone(MODEL.proposals),history:clone(MODEL.history),trash:clone(MODEL.trash),revisions:{},hostTrusted:true});
let D,loadError='';
const params=new URLSearchParams(location.search);
try{if(params.has('reset')){localStorage.removeItem(KEY);params.delete('reset');history.replaceState(null,'',location.pathname+(params.size?'?'+params.toString():''));}D=JSON.parse(localStorage.getItem(KEY))||initial()}catch{D=initial();loadError='无法读取浏览器中的资料，当前显示初始内容。'}
let S={page:params.get('page')||'library',dir:'selfhost',selected:'azure',query:'',filter:'all',plugin:params.get('plugin')||'builtin.server',pluginTab:params.get('tab')||'overview',detailTab:'overview',fileVersion:'v2',request:'server',ttl:'30 分钟',scopes:{server:[true,true,true],resume:[true,true,false]},pluginFilter:'all'};
if(params.get('item')){S.selected=params.get('item');S.dir='all'}
Object.assign(S,{tag:'',groupBy:'none',sort:'updated',setting:params.get('section')||'appearance',proposal:'import',proposalFilter:'all',historyId:'grant-ssh',historyFilter:'all',historyType:'all',queueFilter:'pending',queueQuery:''});
let pending=null,packageErrors=[],draft=null,editId=null,modalFocus=null;
const byId=id=>D.items.find(x=>x.id===id),packageById=id=>D.plugins.find(x=>x.id===id);
const availableTemplates=()=>D.plugins.filter(p=>p.enabled).flatMap(p=>p.templates.map(t=>({...t,packageId:p.id,version:p.version})));
const activeTemplate=i=>i.definition&&packageById(i.packageId)?.enabled;
const btn=(label,attrs='',cls='')=>'<button class="btn '+cls+'" '+attrs+'>'+label+'</button>';
const pill=(label,cls='')=>'<span class="pill '+cls+'">'+e(label)+'</span>';
const graphic=(kind)=>'<span class="object-icon '+kind+'">'+icon(({document:'book',resume:'file',credential:'key',note:'file',domain:'globe',service:'layers',profile:'user'})[kind]||kind)+'</span>';
const kindName=i=>i.definition?.name||({document:'文档',resume:'简历文件',file:'文件',credential:'凭据',note:'通用信息'})[i.kind]||'信息';
const directoryName=id=>D.dirs.find(d=>d.id===id)?.name||'未分类';
const dirContains=(dir,i)=>dir==='all'||i.directory===dir||D.dirs.find(d=>d.id===i.directory)?.parent===dir;
const selected=()=>byId(S.selected);
const relationsHTML=(ids)=>ids.map(byId).filter(Boolean).map(i=>'<button class="relation" data-item="'+e(i.id)+'">'+graphic(i.kind)+'<span class="grow"><strong class="relation-name">'+e(i.name)+'</strong><p>'+e(i.summary)+'</p></span>'+icon('chevron')+'</button>').join('');
function mutate(fn,success){
 const next=clone(D);fn(next);
 try{if(params.has('failStorage'))throw Error('storage');localStorage.setItem(KEY,JSON.stringify(next));D=next;return true}
 catch{const el=(document.querySelector('.modal #form-error,.modal #install-error')||document.getElementById('page-error'));if(el){el.hidden=false;el.textContent='未能保存更改，输入已保留。请检查浏览器存储后重试。'}return false}
}





function fieldValue(value){if(Array.isArray(value))return value.map(v=>typeof v==='object'?Object.values(v).join(' · '):String(v)).map(e).join('<br>');return value?e(value):'<span class="muted">未填写</span>'}
function fieldGrid(i,keys){
 return '<div class="facts">'+keys.map(key=>{const f=i.definition?.fields.find(f=>f.key===key);if(!f)return '';return '<div class="fact"><label>'+e(f.label)+'</label><div class="'+(['url','number','date'].includes(f.type)||key==='host'?'mono':'')+'">'+fieldValue(i.values[key])+'</div></div>'}).join('')+'</div>';
}
function sections(i,definition){
 return definition.sections.map(s=>{
  if(s.kind==='fields')return '<section class="content-section"><h2>'+e(s.title)+'</h2>'+(i.templateId==='server'&&s.keys.includes('host')?serverTrustLink(i):'')+fieldGrid(i,s.keys)+'</section>';
  if(s.kind==='relations'){const ids=i.relations?.[s.key]||[];return '<section class="content-section"><div class="section-head"><h2>'+e(s.title)+'</h2><span class="muted small">'+ids.length+' 项</span></div>'+(ids.length?relationsHTML(ids):'<p class="empty-inline">尚未关联。'+btn('添加关联','data-action="edit"','quiet small')+'</p>')+'</section>'}
  if(s.kind==='text')return '<section class="content-section"><h2>'+e(s.title)+'</h2><p class="body-copy">'+fieldValue(i.values[s.key])+'</p></section>';
  if(s.kind==='timeline')return '<section class="content-section"><h2>'+e(s.title)+'</h2><div class="timeline">'+(i.values[s.key]||[]).map(v=>'<div class="timeline-entry"><time>'+e(v.period)+'</time><h3>'+e(v.title)+'</h3><p>'+e(v.detail)+'</p></div>').join('')+'</div></section>';
  return '';
 }).join('');
}
function generic(i){
 return (i.templateId?'<div class="notice fallback">'+icon('info')+'<span>模板'+(packageById(i.packageId)?'已停用':'未安装')+'，正在使用通用视图。资料和关联均已保留。</span></div>':'')+
 (i.definition?fieldGrid(i,i.definition.fields.map(f=>f.key)):'<p class="body-copy">'+e(i.values.body||i.summary).replace(/\n/g,'<br>')+'</p>')+
 Object.entries(i.relations||{}).filter(([k,ids])=>ids.length).map(([k,ids])=>'<section class="content-section"><h2>'+e(i.definition?.relations.find(r=>r.key===k)?.label||'关联资料')+'</h2>'+relationsHTML(ids)+'</section>').join('');
}
function documentBody(i){
 if(i.values?.body)return '<div class="reading"><p style="white-space:pre-wrap">'+e(i.values.body)+'</p></div>';

 if(i.id!=='https'){
  const details={sshguide:['登录与日常维护','连接前核对主机身份。私钥保存在关联凭据中，获批后由 CLI 准备运行时材料。','确认目标主机、端口和登录用户。|通过批准的凭据使用方式启动 SSH。|检查服务状态并记录维护结果。','ssh -i {{SSH_KEY_FILE}} -p 2222 developer@tokyo.beichen.example'],deploy:['容器与数据目录','应用运行在杭州服务器；持久化数据与容器配置分开保存。','核对应用入口、部署主机和数据目录。|更新前备份配置及持久化数据。|更新后检查应用健康状态和公网入口。','docker compose ps'],nasdoc:['媒体目录与备份','NAS 保管媒体文件与个人资料副本。应用只访问各自需要的目录。','确认共享目录和当前访问账号。|核对挂载路径及读写范围。|检查备份任务与最近同步结果。','/data/media'],workflow:['收件与资源整理','按主题整理收到的资源，下载与登录会话分别管理。','确认资源来源及保存目的。|按需要领取已获准资料或使用登录凭据。|保留来源说明，再归入对应目录。','']};
  const doc=details[i.id]||['用途说明',i.summary,'核对资料来源。|确认本次需要的操作范围。',''];
  return '<div class="reading"><h2>'+e(doc[0])+'</h2><p>'+e(doc[1])+'</p><h2>操作步骤</h2><ol>'+doc[2].split('|').map(step=>'<li>'+e(step)+'</li>').join('')+'</ol>'+(doc[3]?'<pre><code>'+e(doc[3])+'</code></pre>':'')+'</div>'+relationsHTML(i.owner?[i.owner]:[]);
 }
 return '<div class="reading"><h2>用途与适用范围</h2><p>'+e(i.id==='https'?'日本节点作为公网入口，接收 HTTPS 请求，再通过内部网络转发到杭州服务器。应用数据和容器保留在杭州。':i.summary)+'</p><h2>访问入口</h2><table><thead><tr><th>入口</th><th>服务</th></tr></thead><tbody><tr><td>notes.beichen.example</td><td>Blinko 笔记</td></tr><tr><td>tasks.beichen.example</td><td>Vikunja 任务管理</td></tr></tbody></table><h2>维护步骤</h2><ol><li>核对对应服务器与服务的连接资料。</li><li>申请所需凭据，通过获批方式执行操作。</li><li>检查配置和服务状态，记录变更结果。</li></ol><pre><code>caddy validate --config /etc/caddy/Caddyfile</code></pre><p>认证材料单独保存在关联凭据中，操作说明不包含密钥原文。</p></div>'+relationsHTML(i.owner?[i.owner]:[]);
}
function fileBody(i){
 if(i.id.startsWith('core-'))return '<div class="credential-summary">'+icon('file')+'<div><strong>'+e(i.filename||i.name)+'</strong><p>'+e(i.format||'文件')+'</p></div></div><p class="body-copy">'+e(i.summary)+'</p>'+btn('替换文件 / 新版本','data-action="edit"');

 if(i.id==='publickey')return '<div class="facts"><div class="fact"><label>文件格式</label><strong>PEM / PKCS#1</strong></div><div class="fact"><label>文件用途</label><strong>验证 Telegram 服务器身份</strong></div></div><div class="attachment-row">'+icon('file')+'telegram-server-public.pem <span class="grow"></span>'+pill('公钥附件')+'</div>'+relationsHTML(i.related||[]);
 if(i.id==='portrait')return '<div class="portrait-placeholder">'+icon('user')+'<span>证件照 · PNG · 800 × 800</span></div>';
 const resume=i.kind==='resume';
 if(!resume)return '<div class="file-tools">'+pill('PDF')+'<span class="muted small">'+e(i.filename)+'</span></div><div class="file-stage"><div class="resume-paper"><h2>'+e(i.name)+'</h2><p style="margin-top:40px">'+(i.id==='offer'?'林予安：现确认录用岗位为服务端研发。入职日期和工作安排以双方确认的约定为准。':'兹证明林予安于 2026 年 4 月至 8 月在研发团队参与后端相关实习工作。')+'</p><p style="margin-top:24px">'+(i.id==='offer'?'本文用于记录录用岗位、约定时间及入职所需材料。':'实习期间参与任务调度与监控能力开发，完成相关研发工作。')+'</p><p style="text-align:right;margin-top:80px">北辰科技<br>2026 年 8 月</p></div></div>'+relationsHTML(i.related||[]);
 return '<div class="file-tools">'+(i.id==='resume'?'<div class="versions"><button class="'+(S.fileVersion==='v2'?'active':'')+'" data-version="v2">v2 · 已选用</button><button class="'+(S.fileVersion==='v1'?'active':'')+'" data-version="v1">v1 · 历史版</button></div>':'')+'<span class="grow"></span>'+pill('PDF')+'</div><div class="file-stage"><div class="resume-paper"><div class="resume-top"><h2>'+e(resume?'林予安':i.name)+'</h2><span>服务端研发</span></div><p>yuan.lin@example.com · 上海</p><h3>教育经历</h3><p>北辰大学 · 计算机技术硕士</p><p>2024.09 — 2027.06</p><h3>实习经历</h3><p>后端研发实习生 · 2026.04 — 2026.08</p><p>参与任务调度服务开发，完善监控与异常恢复流程。</p><h3>项目经历</h3><p><b>'+e(S.fileVersion==='v1'?'服务端任务管理工具':'个人信息与凭据授权工作台')+'</b></p><p>设计结构化信息访问与凭据使用流程。</p><h3>专业技能</h3><p>Go / Java / SQL · Linux · Docker</p></div></div>'+relationsHTML(i.related||[]);
}
function credentialBody(i){
 const stored=i.id==='tgsession';
 return '<div class="credential-summary">'+icon('shield')+'<div class="grow"><strong>'+e(i.filename||'Token 字符串')+'</strong><p>'+e(i.format)+'</p></div>'+pill(stored?'仅保管':'可使用',stored?'amber':'green')+'</div><section class="content-section"><h2>用途与内容</h2><p class="body-copy">'+e(i.summary)+(stored?'。SQLite 会话文件包含连接参数和账号授权状态，需配合 Telethon 与对应应用信息使用。':'。凭据原文由知予保存，使用时交给执行器。')+'</p></section><section class="content-section"><h2>使用方式</h2>'+(stored?'<div class="notice amber">当前尚不支持此类会话文件的运行时使用。</div>':'<div class="facts"><div class="fact"><label>注入方式</label><strong>'+e(i.delivery==='focus'?'本机焦点填充':i.format.includes('字符串')?'子进程环境变量':'临时凭据文件')+'</strong></div><div class="fact"><label>引用名称</label><strong class="mono">'+e(i.binding)+'</strong></div></div><p class="muted">凭据使用单独审批；在授权期内可按批准方式重复使用。</p>')+'</section><section class="content-section"><h2>关联资料</h2>'+relationsHTML([i.owner])+'</section>';
}
function renderDetail(){
 const i=selected(),root=document.getElementById('record-detail');
 if(!i||!filtered().some(x=>x.id===i.id)){root.innerHTML='<div class="empty"><h2>选择一份资料</h2><p>查看内容、文件与关联关系。</p></div>';document.getElementById('breadcrumb').textContent=directoryName(S.dir);return}
 document.getElementById('breadcrumb').textContent=directoryName(i.directory)+' / '+kindName(i);
 let html=detailHeader(i);
 if(i.templateId){
  html+='<div class="record-tabs"><button class="tab '+(S.detailTab==='overview'?'active':'')+'" data-detail-tab="overview">概览</button><button class="tab '+(S.detailTab==='relations'?'active':'')+'" data-detail-tab="relations">关联资料</button><span class="grow"></span>'+btn('编辑信息','data-action="edit"','quiet small')+'</div>';
  html+=S.detailTab==='relations'?Object.entries(i.relations||{}).map(([k,ids])=>ids.length?'<section class="content-section"><h2>'+e(i.definition.relations.find(r=>r.key===k)?.label||'关联资料')+'</h2>'+relationsHTML(ids)+'</section>':'').join('')||'<div class="empty">还没有关联资料。'+btn('添加关联','data-action="edit"')+'</div>':activeTemplate(i)?sections(i,i.definition):generic(i);
 }else html+=i.kind==='document'?documentBody(i):['resume','file'].includes(i.kind)?fileBody(i):i.kind==='credential'?credentialBody(i):generic(i);
 root.innerHTML='<div class="detail-content">'+html+'</div>';
}
function pluginList(){
 const list=D.plugins.filter(p=>S.pluginFilter==='all'||(S.pluginFilter==='enabled'?p.enabled:!p.enabled));
 return '<div class="plugin-list-head"><h2>已安装</h2><span>'+D.plugins.length+' 个插件</span></div><div class="segment"><button class="'+(S.pluginFilter==='all'?'active':'')+'" data-plugin-filter="all">全部</button><button class="'+(S.pluginFilter==='enabled'?'active':'')+'" data-plugin-filter="enabled">已启用</button><button class="'+(S.pluginFilter==='disabled'?'active':'')+'" data-plugin-filter="disabled">已停用</button></div><div class="scroll plugin-list">'+(list.length?list.map(p=>'<button class="plugin-row '+(S.plugin===p.id?'selected':'')+'" data-package="'+p.id+'">'+graphic(p.templates[0].icon==='layers'?'service':p.templates[0].icon)+'<span class="grow"><strong>'+e(p.name)+'</strong><p>'+e(p.description)+'</p><small>'+e(p.origin||'本地安装')+' · v'+p.version+' · '+(p.enabled?'已启用':'已停用')+'</small></span></button>').join(''):'<p class="empty-inline">没有这个状态的插件。</p>')+'</div>';
}

function templatePreview(t){
 const example=t.example?.values||{},value=f=>example[f.key]?e(example[f.key]):'<span class="placeholder">'+(f.type==='entries'?'可添加多段记录':'填写'+e(f.label))+'</span>';
 return '<div class="preview-caption">'+icon(t.icon)+'<strong>'+e(t.name)+'</strong></div>'+t.sections.map(s=>{
 if(s.kind==='fields')return '<section><h3>'+e(s.title)+'</h3><div class="preview-fields">'+s.keys.map(k=>{const f=t.fields.find(f=>f.key===k);return '<div><label>'+e(f.label)+'</label><p>'+value(f)+'</p></div>'}).join('')+'</div></section>';
 if(s.kind==='relations')return '<section><h3>'+e(s.title)+'</h3><p class="placeholder">'+icon('link')+'可关联已有资料，也可以暂不填写</p></section>';
 if(s.kind==='text'||s.kind==='timeline'){const f=t.fields.find(f=>f.key===s.key);return '<section><h3>'+e(s.title)+'</h3><p>'+value(f)+'</p></section>'}
 return '';
 }).join('');
}
function pluginsPage(){
 return '<div class="plugins-page"><div class="page-head"><div><h1>插件</h1><p>管理资料模板与插件专属设置。已有资料始终由信息库保存。</p></div><div class="row">'+btn('交给 Agent 制作','data-action="agent-brief"')+btn(icon('plus')+'安装插件包','data-action="install"','primary')+'</div></div><div id="page-error" class="form-error" hidden></div><div class="plugin-workspace"><aside class="plugin-sidebar">'+pluginList()+'<div class="plugin-sidebar-foot">'+icon('info')+'普通信息、文档、文件和凭据无需安装插件。</div></aside><section class="plugin-detail scroll">'+pluginDetail(packageById(S.plugin))+'</section></div></div>';
}


function toast(message){
 document.getElementById('toast-root').innerHTML='<div class="toast">'+icon('check')+e(message)+'</div>';
 clearTimeout(window.toastTimer);window.toastTimer=setTimeout(()=>document.getElementById('toast-root').innerHTML='',4500);
}
function modal(title,body,footer='',wide=false){
 if(!document.querySelector('.modal'))modalFocus=document.activeElement;
 hideMenu();document.getElementById('modal-root').innerHTML='<div class="modal-scrim"><section class="modal '+(wide?'wide':'')+'" role="dialog" aria-modal="true" aria-label="'+e(title)+'"><header class="modal-head"><h2>'+e(title)+'</h2>'+btn(icon('x'),'data-action="close" aria-label="关闭"','quiet icon-only')+'</header><div class="modal-body">'+body+'</div>'+(footer?'<footer class="modal-foot">'+footer+'</footer>':'')+'</section></div>';
 document.querySelector('.modal input:not([type=file]),.modal textarea,.modal button')?.focus();
}
function closeModal(){hideMenu();document.getElementById('modal-root').innerHTML='';if(modalFocus?.isConnected)modalFocus.focus()}

function startForm(templateId,editing=false){
 const item=editing&&selected();editId=item?.id||null;
 const t=item?.definition||availableTemplates().find(t=>t.id===templateId);
 draft={name:item?.name||'',summary:item?.summary||'',directory:item?.directory||(S.dir==='all'?'unfiled':S.dir),values:clone(item?.values||{}),relations:clone(item?.relations||{}),definition:t?clone(t):null,templateId:t?.id||null,packageId:item?.packageId||t?.packageId||null,templateVersion:item?.templateVersion||t?.version||null};
 form();
}
function entryInputs(f,entries){
 return '<div class="entry-group"><label>'+e(f.label)+'</label>'+entries.map((v,n)=>'<div class="entry-form"><input data-entry="'+f.key+'" data-index="'+n+'" data-part="title" aria-label="经历名称" placeholder="学校 / 岗位" value="'+e(v.title||'')+'"><input data-entry="'+f.key+'" data-index="'+n+'" data-part="period" aria-label="经历时间" placeholder="时间范围" value="'+e(v.period||'')+'"><textarea data-entry="'+f.key+'" data-index="'+n+'" data-part="detail" aria-label="经历说明" placeholder="说明">'+e(v.detail||'')+'</textarea></div>').join('')+btn(icon('plus')+'添加一段','data-add-entry="'+f.key+'"','quiet small')+'</div>';
}
function form(){
 const t=draft.definition;
 modal(editId?'编辑信息':'添加'+(t?.name||'通用信息'),'<form id="record-form"><div id="form-error" class="form-error" hidden></div><div class="form-topline"><span>'+icon(t?.icon||'file')+' '+e(t?.name||'通用信息')+(draft.templateVersion?' · v'+e(draft.templateVersion):'')+'</span><span class="grow"></span>'+btn(icon('folder')+e(directoryName(draft.directory))+icon('down'),'type="button" data-menu="directory" id="directory-choice"','small')+'</div><div class="form-pair"><div class="input-field"><label for="record-name">资料名称</label><input id="record-name" required maxlength="100" placeholder="用你习惯的名字" value="'+e(draft.name)+'"></div><div class="input-field"><label for="record-summary">用途说明 <span>选填</span></label><input id="record-summary" maxlength="200" placeholder="什么时候会用到它" value="'+e(draft.summary)+'"></div></div><div class="form-grid">'+(t?t.fields.map(f=>f.type==='entries'?entryInputs(f,draft.values[f.key]||[]):'<div class="input-field '+(f.type==='multiline'?'span-2':'')+'"><label for="f-'+f.key+'">'+e(f.label)+(f.required?'':' <span>选填</span>')+'</label>'+(f.type==='multiline'?'<textarea data-value="'+f.key+'" id="f-'+f.key+'">'+e(draft.values[f.key]||'')+'</textarea>':'<input id="f-'+f.key+'" data-value="'+f.key+'" '+(f.required?'required':'')+' type="'+(f.type==='number'?'number':'text')+'" '+(f.type==='number'?'min="1" max="65535"':'')+' placeholder="'+(f.type==='date'?'YYYY-MM-DD':'')+'" value="'+e(draft.values[f.key]||'')+'">')+'</div>').join(''):'<div class="input-field span-2"><label for="f-body">内容</label><textarea id="f-body" data-value="body" rows="6">'+e(draft.values.body||'')+'</textarea></div>')+'</div>'+(t?'<section class="form-relations"><h3>关联资料 <span class="muted small">选填</span></h3>'+t.relations.map(r=>'<div class="form-relation"><span>'+e(r.label)+'</span>'+btn((draft.relations[r.key]||[]).length?e(draft.relations[r.key].map(id=>byId(id)?.name).filter(Boolean).join('、')):icon('plus')+'选择已有资料','type="button" data-relation-menu="'+r.key+'"','small')+'</div>').join('')+'</section>':'')+'</form>',btn('取消','data-action="close"')+'<button class="btn primary" type="submit" form="record-form">保存信息</button>',true);
}
function collectDraft(){
 if(!document.getElementById('record-form'))return;
 draft.name=document.getElementById('record-name').value;draft.summary=document.getElementById('record-summary').value;
 document.querySelectorAll('[data-value]').forEach(input=>draft.values[input.dataset.value]=input.value);
 document.querySelectorAll('[data-entry]').forEach(input=>{const {entry,index,part}=input.dataset;draft.values[entry]??=[];draft.values[entry][index]??={};draft.values[entry][index][part]=input.value});
}
function saveRecord(){
 collectDraft();if(!draft.name.trim())return;
 const t=draft.definition,id=editId||'item-'+crypto.randomUUID();
 const old=editId&&byId(editId);
 if(t){const bad=t.fields.find(f=>f.type==='date'&&draft.values[f.key]&&!/^\d{4}-\d{2}-\d{2}$/.test(draft.values[f.key]));if(bad){const err=document.getElementById('form-error');err.hidden=false;err.textContent=bad.label+'请使用 YYYY-MM-DD 格式。';document.getElementById('f-'+bad.key).focus();return}}
 const item={...old,...clone(draft),id,name:draft.name.trim(),summary:draft.summary.trim(),kind:old?.kind||(t?.icon==='layers'?'service':t?.icon==='user'?'profile':t?.icon==='globe'?'domain':t?.icon||'note'),updated:'刚刚',tags:old?.tags||[],updatedAt:'2026-10-23'};
 if(mutate(next=>{const n=next.items.findIndex(i=>i.id===id);n<0?next.items.push(item):(next.revisions[id]??=[],next.revisions[id].push(clone(next.items[n])),next.items[n]=item)})){closeModal();S.dir=item.directory;goItem(id);toast(editId?'信息已保存':'已添加到'+directoryName(item.directory))}
}
function validatePackage(p){
 const errors=[],supportedFields=['text','url','number','date','multiline','entries'],supportedSections=['fields','relations','text','timeline'];
 if(!p||typeof p!=='object'||Array.isArray(p))return ['插件包必须是 JSON 对象。'];
 if(!/^[a-z][a-z0-9.-]{2,80}$/.test(p.id||''))errors.push('插件标识无效。');
 if(p.id?.startsWith('builtin.'))errors.push('本地插件包不能覆盖内置插件。');
 if(typeof p.name!=='string'||!p.name.trim())errors.push('缺少插件名称。');
 if(!/^\d+\.\d+\.\d+$/.test(p.version||''))errors.push('版本应为三个数字，例如 1.0.0。');
 if(p.hostApi!==1)errors.push('插件要求的软件接口版本不兼容。');
 if(!Array.isArray(p.templates)||!p.templates.length||p.templates.length>10)return errors.concat('插件需要包含 1–10 个模板。');
 const seen=new Set();
 p.templates.forEach(t=>{
  if(!t||typeof t!=='object'){errors.push('模板定义必须是对象。');return}
  if(!['server','layers','user','globe','briefcase','book','file','folder','key'].includes(t.icon))errors.push('模板图标不受支持。');
  if(!/^[a-z][a-z0-9_-]{1,60}$/.test(t.id||'')||seen.has(t.id))errors.push('模板标识无效或重复。');seen.add(t.id);
  if(typeof t.name!=='string'||!t.name.trim())errors.push('模板缺少名称。');
  const owner=D.plugins.find(pack=>pack.id!==p.id&&pack.templates.some(x=>x.id===t.id));if(owner)errors.push('模板标识与“'+owner.name+'”冲突。');
  if(!Array.isArray(t.fields)||t.fields.length>40||!Array.isArray(t.sections)||!Array.isArray(t.relations)){errors.push('字段、布局或关联定义缺失。');return}
  const keys=new Set();
  t.fields.forEach(f=>{if(!f||typeof f!=='object'){errors.push('字段定义必须是对象。');return}if(!/^[a-z][a-zA-Z0-9_]{0,60}$/.test(f.key||'')||keys.has(f.key)||!f.label||!supportedFields.includes(f.type))errors.push('字段定义无效或不受支持。');keys.add(f.key)});
  const relationKeys=new Set();
  t.relations.forEach(r=>{if(!r||typeof r!=='object'){errors.push('关联定义必须是对象。');return}if(!/^[a-z][a-zA-Z0-9_]{0,60}$/.test(r.key||'')||!r.label||relationKeys.has(r.key)||!Array.isArray(r.targetTemplates)||r.targetTemplates.some(k=>typeof k!=='string'))errors.push('关联定义无效。');relationKeys.add(r.key)});
  t.sections.forEach(s=>{if(!s||typeof s!=='object'){errors.push('布局定义必须是对象。');return}if(!supportedSections.includes(s.kind)||!s.title)errors.push('含有不支持的展示方式。');else if(s.kind==='fields'&&(!Array.isArray(s.keys)||s.keys.some(k=>!keys.has(k))))errors.push('布局引用了不存在的字段。');else if(['text','timeline'].includes(s.kind)&&!keys.has(s.key))errors.push('布局引用了不存在的内容。');else if(s.kind==='relations'&&!relationKeys.has(s.key))errors.push('布局引用了不存在的关联。');else if(s.kind==='timeline'&&t.fields.find(f=>f?.key===s.key)?.type!=='entries')errors.push('时间线需要多段记录字段。')});
  if(typeof t.instructions!=='string')errors.push('缺少 Agent 录入说明。');
 });
 if(packageById(p.id))errors.push('已安装此插件。请在插件详情中管理已有版本。');
 return [...new Set(errors)];
}
function installDialog(){
 const ok=pending&&!packageErrors.length;
 modal('安装模板插件',pending?'<div id="install-error" class="form-error" '+(packageErrors.length?'':'hidden')+'>'+packageErrors.map(e).join('<br>')+'</div><div class="install-intro"><div>'+graphic(pending.templates?.[0]?.icon==='layers'?'service':pending.templates?.[0]?.icon||'plugin')+'</div><div class="grow"><h2>'+e(pending.name||'未命名插件')+'</h2><p>'+e(pending.description||'')+'</p><span class="muted small">本地文件 · 作者：'+e(pending.author||'未提供')+' · v'+e(pending.version||'未知')+'</span></div>'+(ok?pill('格式检查通过','green'):pill('需要修正','amber'))+'</div>'+(ok?'<div class="install-columns"><aside><h3>将添加什么</h3><p>'+pending.templates.length+' 个信息模板</p><p>'+pending.templates.reduce((n,t)=>n+t.fields.length,0)+' 个字段定义</p><p>'+pending.templates.reduce((n,t)=>n+t.relations.length,0)+' 种可选关联</p><div class="rule"><h3>现有资料</h3><p>不会自动修改或迁移。</p></div><div class="rule"><h3>安装后</h3><p>“添加资料”中可直接选择新模板，目录仍由你决定。</p></div></aside><div><h3 style="margin-bottom:12px">模板预览</h3><div class="template-sheet">'+templatePreview(pending.templates[0])+'</div></div></div>':'<p class="body-copy">请让 Agent 修正上面的定义，再重新选择插件包。</p>'):'<div id="install-error" class="form-error" hidden></div><div class="import-zone">'+icon('plugin')+'<h3>选择 Agent 制作好的插件包</h3><p>先查看模板结构和展示效果，再安装到信息库。</p><label class="btn primary file-label">选择插件包<input id="package-file" type="file" accept=".json,application/json"></label></div><div class="sample-package">'+graphic('domain')+'<div class="grow"><strong>域名管理</strong><p>注册商、到期时间、DNS 服务与关联服务器。</p></div>'+btn('预览域名插件','data-action="sample-package"')+'</div><div class="muted small">还没有插件包？ '+btn('把需求交给 Agent','data-action="agent-brief"','quiet small')+'</div>',btn(pending?'重新选择':'取消',pending?'data-action="install"':'data-action="close"')+(ok?btn('安装并添加资料','data-action="install-package"','primary'):''),true);
 if(pending)document.querySelector('.modal-foot .primary')?.focus();
}
function installPackage(){
 if(!pending||validatePackage(pending).length)return;
 const p={...clone(pending),enabled:true,origin:'本地安装'};
 if(mutate(next=>next.plugins.push(p))){closeModal();S.page='settings';S.setting='plugins';S.plugin=p.id;S.pluginTab='overview';render();toast('已安装'+p.name);startForm(p.templates[0].id)}
}
function agentBrief(){
 modal('交给 Agent 制作模板','<p class="muted">用自然语言描述要保存什么，Agent 负责字段、展示和录入规则。</p><div class="input-field"><label for="brief">我的需求</label><textarea id="brief" rows="4">我想管理域名，需要记录注册商、到期日期、DNS 服务和用途。有明确依据时关联服务器，不要求必须关联。</textarea></div><div class="brief-process"><div><b>1</b><span>描述用途</span></div>'+icon('arrow')+'<div><b>2</b><span>Agent 制作插件包</span></div>'+icon('arrow')+'<div><b>3</b><span>预览并安装</span></div></div><div class="notice">'+icon('file')+'<span>说明包含先复用已有模板、提供示例、保持授权方式不变，以及插件检查要求。</span></div><details class="brief-details"><summary>查看制作约定</summary><p>字段与布局用插件包定义；实际信息保存在软件中。安装插件不代表允许读取现有资料。新增或更新信息继续通过录入提案处理。</p><a href="plugin-spec.md" target="_blank">打开本轮插件规范</a></details><div id="copy-error" class="form-error" hidden></div>',btn('关闭','data-action="close"')+btn('复制给 Agent','data-action="copy-brief"','primary'));
}
function updateDialog(){
 const p=packageById('builtin.server'),count=D.items.filter(i=>i.packageId===p.id).length;
 modal('更新服务器信息','<div class="version-path">'+pill('v1.0.0')+icon('arrow')+pill('v1.1.0','purple')+'</div><h3>新增可选字段</h3><p class="body-copy">维护负责人：显示在连接概览中，方便确认联系对象。</p><div class="notice">'+icon('info')+'<span>已有 '+count+' 项资料继续使用各自保存的字段结构。更新只影响之后新建的信息，不改写内容或扩展已有授权。</span></div><div id="form-error" class="form-error" hidden></div>',btn('取消','data-action="close"')+btn('安装更新','data-action="apply-update"','primary'));
}

let menuTrigger=null;
function hideMenu(){document.getElementById('menu-root').innerHTML=''}

function showMenu(t){
 if(t.dataset.menu==='filter')menu(t,[['all','所有模板'],...availableTemplates().map(x=>[x.id,x.name]),['document','文档'],['file','文件'],['credential','凭据']].map(([id,label])=>'<button data-filter="'+id+'">'+e(label)+(S.filter===id?icon('check'):'')+'</button>').join(''));
 if(t.dataset.menu==='directory'){collectDraft();menu(t,D.dirs.filter(d=>d.id!=='all').map(d=>'<button data-pick-directory="'+d.id+'">'+icon('folder')+e(d.name)+(draft.directory===d.id?icon('check'):'')+'</button>').join(''))}
 if(t.dataset.menu==='ttl')menu(t,(S.request==='organize'?['15 分钟','30 分钟']:['15 分钟','30 分钟','1 小时']).map(v=>'<button data-ttl="'+v+'">'+v+'</button>').join(''));
 if(t.dataset.relationMenu){collectDraft();const r=draft.definition.relations.find(r=>r.key===t.dataset.relationMenu);const list=D.items.filter(i=>i.id!==editId&&(!r.targetTemplates.length||r.targetTemplates.includes(i.templateId)));menu(t,'<div class="menu-heading">'+e(r.label)+' · 可多选</div><button data-pick-relation="" data-key="'+r.key+'">清除关联</button>'+list.map(i=>'<button data-pick-relation="'+i.id+'" data-key="'+r.key+'"><span class="grow">'+e(i.name)+'</span>'+((draft.relations[r.key]||[]).includes(i.id)?icon('check'):icon('plus'))+'</button>').join(''))}
}
/* Round 09: everyday navigation, simple discovery, complete product surfaces. */
function liveItems(){return D.items.filter(i=>!i.deletedAt)}
function positionMenu(){
 const el=document.querySelector('.floating-menu');if(!el||!menuTrigger?.isConnected)return;
 const box=menuTrigger.getBoundingClientRect();if(box.bottom<60||box.top>innerHeight){hideMenu();return}
 const below=innerHeight-box.bottom-16,above=box.top-16;
 el.style.width=Math.min(340,Math.max(box.width,230))+'px';
 el.style.maxHeight=Math.max(100,Math.min(340,Math.max(below,above)))+'px';
 const h=el.offsetHeight;el.style.left=Math.max(12,Math.min(box.right-el.offsetWidth,innerWidth-el.offsetWidth-12))+'px';el.style.top=(below>=h?box.bottom+6:Math.max(12,box.top-h-6))+'px';
}
function menu(trigger,content){
 hideMenu();menuTrigger=trigger;document.getElementById('menu-root').innerHTML='<div class="floating-menu" role="menu">'+content+'</div>';positionMenu();document.querySelector('.floating-menu button')?.focus({preventScroll:true});
}


function groupValue(i,g){return g==='template'?kindName(i):g==='directory'?directoryName(i.directory):''}
function typeChoices(){
 const types=new Map();for(const i of liveItems()){const id=i.templateId||(i.kind==='resume'?'file':i.kind);types.set(id,i.kind==='resume'?'文件':kindName(i))}return [...types];
}
function filtered(state=S){
 const words=state.query.trim().toLowerCase().split(/\s+/).filter(Boolean);
 const rows=liveItems().filter(i=>dirContains(state.dir,i)&&(state.filter==='all'||i.templateId===state.filter||i.kind===state.filter||(state.filter==='file'&&i.kind==='resume'))&&(!state.tag||(i.tags||[]).includes(state.tag))&&words.every(word=>(i.name+' '+i.summary+' '+kindName(i)+' '+(i.tags||[]).join(' ')).toLowerCase().includes(word)));
 return rows.sort((a,b)=>state.sort==='name'?a.name.localeCompare(b.name,'zh-CN'):(b.updatedAt||'').localeCompare(a.updatedAt||''));
}
function filterControls(){
 return btn('<span>'+e(typeChoices().find(x=>x[0]===S.filter)?.[1]||'全部类型')+'</span>'+icon('down'),'data-xmenu="type" aria-label="资料类型" aria-haspopup="menu"','small '+(S.filter!=='all'?'applied':''))+btn('<span>'+e(S.tag||'全部标签')+'</span>'+icon('down'),'data-xmenu="tag" aria-label="资料标签" aria-haspopup="menu"','small '+(S.tag?'applied':''));
}

function directoryNav(){
 return '<div class="side-label">资料目录</div>'+D.dirs.map(d=>'<button class="directory '+(d.parent?'child ':'')+(S.dir===d.id?'active':'')+'" data-dir="'+d.id+'">'+icon(d.icon)+'<span>'+e(d.name)+'</span><small>'+liveItems().filter(i=>dirContains(d.id,i)).length+'</small></button>').join('')+'<button class="directory subtle" data-action="new-directory">'+icon('plus')+'新建目录</button><div class="side-divider"></div><div class="side-label row"><span class="grow">标签</span>'+btn('管理','data-setting="labels"','quiet small')+'</div><div class="tag-cloud">'+D.tags.slice(0,7).map(tag=>'<button class="tag '+(S.tag===tag?'active':'')+'" data-tag="'+e(tag)+'">'+e(tag)+'</button>').join('')+'</div>';
}

function libraryShell(){
 return '<div class="workspace"><aside class="side"><div class="side-scroll scroll" id="directory-nav">'+directoryNav()+'</div><footer class="side-footer"><button class="directory" data-action="recycle">'+icon('trash')+'回收站 <small>'+D.trash.length+'</small></button><p><span class="status-dot"></span>资料保存在本机</p></footer></aside><section class="browse-pane"><div class="browse-header"><div class="row spread"><h2 id="list-title">'+e(directoryName(S.dir))+'</h2>'+btn(icon('plus'),'data-action="new" aria-label="添加资料"','quiet icon-only')+'</div><div class="search">'+icon('search')+'<input id="search" aria-label="搜索当前范围" placeholder="搜索名称、用途、标签" value="'+e(S.query)+'"><kbd>⌃ K</kbd></div><div class="simple-filters" id="filter-controls">'+filterControls()+'</div><div class="row browse-tools"><span class="muted small" id="result-count"></span>'+btn(icon('grid')+'分组','data-xmenu="group" aria-haspopup="menu"','quiet small')+btn(icon('sort')+'排序','data-xmenu="sort" aria-haspopup="menu"','quiet small')+'</div></div><div class="scroll" id="record-list"></div><footer class="browse-footer"><span id="list-order"></span></footer></section><main class="detail-shell"><div class="detail-toolbar"><span id="breadcrumb"></span><span class="grow"></span>'+btn('添加资料','data-action="new"','quiet')+'</div><div class="scroll" id="detail-scroll"><div id="record-detail"></div></div></main></div>';
}

function renderList(){
 const list=filtered(),groups=new Map();
 for(const i of list){const group=groupValue(i,S.groupBy);if(!groups.has(group))groups.set(group,[]);groups.get(group).push(i)}
 document.getElementById('record-list').innerHTML=list.length?[...groups].map(([g,items])=>(g?'<div class="list-group">'+e(g)+'<span>'+items.length+'</span></div>':'')+items.map(i=>'<button class="list-item '+(S.selected===i.id?'selected':'')+'" data-item="'+e(i.id)+'">'+graphic(i.kind)+'<span class="grow"><strong>'+e(i.name)+'</strong><span class="item-summary">'+e(i.summary)+'</span><span class="item-meta">'+e(kindName(i))+'</span>'+(i.tags?.length?'<span class="list-tags">'+i.tags.slice(0,2).map(t=>'<span>'+e(t)+'</span>').join('')+'</span>':'')+'</span></button>').join('')).join(''):'<div class="empty"><h2>没有匹配的资料</h2><p>换个关键词，或取消类型和标签。</p>'+btn('清除筛选','data-action="clear"')+'</div>';
 document.getElementById('result-count').textContent=list.length+' 项';
 document.getElementById('filter-controls').innerHTML=filterControls();
 document.getElementById('list-order').textContent=groupName(S.groupBy)+' · '+(S.sort==='name'?'按名称':'最近更新优先');
}
function detailHeader(i){
 return '<div class="detail-header">'+graphic(i.kind)+'<div class="grow"><h1>'+e(i.name)+'</h1><p>'+e(i.summary)+'</p><div class="detail-meta">'+pill(kindName(i))+(i.tags||[]).map(t=>'<button class="tag" data-tag="'+e(t)+'">'+e(t)+'</button>').join('')+btn(icon('plus')+'标签','data-action="edit-tags"','quiet small')+'</div></div><div class="row">'+btn(icon('expand'),'data-action="expand" aria-label="展开阅读"','quiet icon-only')+btn(icon('more'),'data-xmenu="record" aria-label="资料操作"','quiet icon-only')+'</div></div>';
}
function goItem(id){
 const i=byId(id);if(!i)return;const inResults=S.page==='library'&&filtered().some(x=>x.id===id);S.page='library';S.selected=id;S.detailTab='overview';if(!inResults){S.query='';S.filter='all';S.tag='';if(!dirContains(S.dir,i))S.dir=i.directory}render();
}

function groupName(g){return ({none:'不分组',template:'按类型',directory:'按目录'})[g]||'不分组'}
function chooser(){
 editId=null;modal('添加资料','<div class="chooser-intro"><p>选择资料的内容形式。</p><span>保存到 '+e(directoryName(S.dir==='all'?'unfiled':S.dir))+'</span></div><div class="template-choices">'+availableTemplates().map(t=>'<button class="template-choice" data-new-template="'+t.id+'">'+graphic(t.icon==='layers'?'service':t.icon)+'<span class="grow"><strong>'+e(t.name)+'</strong><p>'+e(packageById(t.packageId).description)+'</p></span>'+icon('chevron')+'</button>').join('')+'<div class="core-choices">'+[['generic','通用信息','file'],['document','文档','book'],['file','普通文件','file'],['credential','凭据','key']].map(([id,n,ic])=>'<button '+(id==='generic'?'data-new-template="generic"':'data-core-new="'+id+'"')+'>'+icon(ic)+n+'</button>').join('')+'</div></div><div class="chooser-bottom">其他资料结构可在'+btn('设置 · 插件','data-setting="plugins"','quiet')+'中添加。</div>');
}
function render(){
 hideMenu();if(S.setting==='ssh'){S.setting='plugins';S.plugin='builtin.server';S.pluginTab='settings'}if(S.page==='plugins'){S.page='settings';S.setting='plugins'}
 document.body.dataset.theme=D.settings.theme==='dark'?'dark':'light';
 document.querySelectorAll('.topnav [data-page]').forEach(b=>b.classList.toggle('active',b.dataset.page===S.page));
 document.getElementById('pending-count').textContent=requests().filter(r=>!D.decisions[r.id]).length;
 document.getElementById('proposal-count').textContent=D.proposals.filter(p=>p.status==='待确认').length;
 const page=S.page==='library'?libraryShell():S.page==='settings'?settingsPage():S.page==='proposals'?proposalsPage():S.page==='history'?historyPage():S.page==='recycle'?recyclePage():approvalsPage();
 document.getElementById('main').innerHTML=page;
 if(S.page==='library'){renderList();renderDetail();document.querySelector('.list-item.selected')?.scrollIntoView({block:'nearest'})}
 if(loadError){toast(loadError);loadError=''}
}
function settingsNav(){
 return [['appearance','layers','外观','明亮与黑暗主题'],['notifications','inbox','通知','访问申请提醒'],['records','clock','请求与记录','等待时间与保留期限'],['plugins','plugin','插件','资料模板与专属设置'],['labels','folder','目录与标签','归放位置与标签'],['backups','shield','备份与恢复','加密备份与恢复密钥'],['runtime','sliders','应用运行','本机服务与材料维护'],['agents','link','Agent 接入','会话关联与接入状态']];
}
function settingRow(title,description,control){return '<div class="setting-row"><div><h3>'+title+'</h3><p>'+description+'</p></div><div class="setting-control">'+control+'</div></div>'}
function switchButton(key,label){return '<button class="switch '+(D.settings[key]?'on':'')+'" role="switch" aria-checked="'+D.settings[key]+'" aria-label="'+label+'" data-toggle-setting="'+key+'"><span></span></button>'}
function settingsPage(){
 const entries=settingsNav(),entry=entries.find(a=>a[0]===S.setting)||entries[0];
 return '<div class="settings-shell"><aside class="settings-nav scroll"><h1>设置</h1>'+entries.map(([id,ic,n,desc])=>'<button class="settings-link '+(S.setting===id?'active':'')+'" data-setting="'+id+'">'+icon(ic)+'<span><strong>'+n+'</strong><small>'+desc+'</small></span></button>').join('')+'</aside><main class="settings-main '+(S.setting==='plugins'?'settings-plugin-main':'scroll')+'">'+(S.setting==='plugins'?pluginsPage():'<div class="settings-content"><header class="settings-heading"><h1>'+entry[2]+'</h1><p>'+entry[3]+'</p></header><div id="page-error" class="form-error" hidden></div>'+settingsBody()+'</div>')+'</main></div>';
}
function settingsBody(){
 const s=D.settings;
 if(S.setting==='appearance')return '<h2>界面主题</h2><p class="section-desc">选择适合当前光线的阅读方式。</p><div class="theme-options">'+[['light','明亮','浅灰底色，清晰留白'],['dark','黑暗','深灰层次，柔和对比']].map(([id,n,desc])=>'<button class="theme-choice '+((s.theme==='dark'?'dark':'light')===id?'chosen':'')+'" data-theme="'+id+'" aria-pressed="'+((s.theme==='dark'?'dark':'light')===id)+'"><span class="theme-preview preview-'+id+'"><i></i><b></b><b></b><em></em></span><span class="theme-label"><strong>'+n+'</strong><small>'+desc+'</small></span><span class="theme-check">'+((s.theme==='dark'?'dark':'light')===id?icon('check'):'')+'</span></button>').join('')+'</div><div class="settings-card">'+settingRow('阅读层次','背景、列表和详情用不同明度区分；强调色只用于当前选择与主要操作。',icon('layers'))+settingRow('资料识别','保留服务器、文件和凭据的图标色，并始终显示类型名称。',icon('file'))+'</div>';
 if(S.setting==='notifications')return '<div class="settings-card">'+settingRow('访问申请通知','收到新申请时提醒。通知只显示请求概况，不包含字段值和密钥。',switchButton('notifications','访问申请通知'))+settingRow('检查提醒效果','预览通知的标题、说明与点击后的去向。',btn('预览通知','data-preview="notification"'))+'</div><div class="quiet-note">'+icon('info')+'系统通知权限、勿扰模式和专注助手也会影响提醒显示。</div>';
 if(S.setting==='records')return '<div class="settings-card">'+settingRow('等待审批时间','超过等待时间，未处理的申请自动过期。只影响新申请。',btn(s.wait+icon('down'),'data-xmenu="setting-wait"'))+settingRow('授权期限','每次审批单独选择。在批准的方式与当前会话内，可以反复调用。',btn('前往审批','data-page="approvals"','quiet'))+settingRow('记录保留期限','只保存授权范围与访问事件，不保存字段值。缩短期限前先确认清理范围。',btn(s.retention+icon('down'),'data-xmenu="setting-retention"'))+'</div><div class="quiet-note">'+icon('clock')+'回收站与内容版本保留 30 天，和访问记录的保留期限分别管理。</div>';
 if(S.setting==='labels')return '<div class="setting-tabs"><button class="tab active">目录与标签</button></div><div class="management-section"><div class="row spread"><h2>目录</h2>'+btn(icon('plus')+'新建目录','data-action="new-directory"')+'</div><p class="section-desc">每份资料有一个归放位置。目录可包含不同类型的资料。</p>'+D.dirs.filter(d=>!['all','unfiled'].includes(d.id)).map(d=>'<div class="manage-row '+(d.parent?'nested':'')+'">'+icon('folder')+'<span class="grow">'+e(d.name)+'</span><small>'+liveItems().filter(i=>dirContains(d.id,i)).length+' 项</small>'+btn('重命名','data-rename-dir="'+d.id+'"','quiet small')+btn('查看','data-dir="'+d.id+'" data-page="library"','quiet small')+'</div>').join('')+'</div><div class="management-section"><div class="row spread"><h2>标签</h2>'+btn(icon('plus')+'新建标签','data-action="new-tag"')+'</div><p class="section-desc">一份资料可以有多个标签；可在当前目录中按类型、标签筛选，再用关键词查找。</p><div class="managed-tags">'+D.tags.map(tag=>'<button class="managed-tag" data-rename-tag="'+e(tag)+'"><span>'+e(tag)+'</span><small>'+liveItems().filter(i=>(i.tags||[]).includes(tag)).length+'</small>'+icon('edit')+'</button>').join('')+'</div></div>';
 if(S.setting==='backups')return '<div class="backup-intro">'+icon('shield')+'<div><h2>备份整个信息库</h2><p>包括信息、普通文件、凭据、目录与标签，以及使用的模板定义。</p></div></div><div class="settings-card">'+settingRow('创建加密备份','使用独立的恢复密钥。建议把备份文件与恢复密钥分开保管。',btn('创建备份','data-preview="backup"','primary'))+settingRow('从备份恢复','先校验文件与恢复密钥，再确认恢复范围和已有资料处理方式。',btn('恢复备份','data-preview="restore"'))+settingRow('恢复密钥','它用于解密备份，不会随备份文件一同保存。',btn('查看保管说明','data-preview="recovery-key"','quiet'))+'</div>';
 if(S.setting==='runtime')return '<div class="settings-card">'+settingRow('本机服务运行中','Agent 从这里提交申请；实际读取和使用仍需授权。',pill('已连接','green'))+settingRow('临时凭据材料','在执行结束后检查临时文件；活动进程使用中的文件暂不清理。',btn('查看材料','data-preview="materials"'))+settingRow('普通附件维护','撤销或到期后回收已登记副本；原文按内容保留期限清理。',btn('核查附件','data-preview="attachments"'))+settingRow('关闭窗口后继续运行','收起到系统托盘，继续接收申请。',switchButton('tray','关闭窗口后继续运行'))+settingRow('完全退出应用','停止本机服务，并结束当前会话的授权。',btn('完全退出','data-preview="quit"'))+'</div>';
 return '<div class="settings-card"><div class="agent-connection"><span class="agent-letter">C</span><div class="grow"><h2>Codex</h2><p>通过 Skill 与会话 hooks 接入</p></div>'+pill('已连接','green')+'</div>'+settingRow('会话关联','每个聊天独立关联，会话结束时对应授权失效。',btn('查看接入流程','data-preview="agent-connect"'))+settingRow('Agent 录入约定','先复用模板；目录按用途，标签按查找习惯。关联必须有来源依据。',btn('查看说明','data-preview="agent-rules"'))+'</div><p class="section-desc">接入状态、申请发起方和资料访问权限分别显示；连接成功不会自动获得资料权限。</p>';
}
function requests(){return [
 {id:'server',title:'检查反向代理服务',type:'凭据与字段',agent:'Codex',time:'15:20',purpose:'检查 Caddy 状态，核对站点入口及证书配置。',scopes:['Azure SSH 私钥使用','服务器地址','登录用户与端口'],item:'sshkey',binding:'SSH_KEY_FILE → 临时私钥文件 → -i 参数',command:'ssh -i {{SSH_KEY_FILE}} -p 2222 developer@tokyo.beichen.example "systemctl status caddy"'},
 {id:'resume',title:'填写招聘网站资料',type:'文件与字段',agent:'Codex',time:'15:18',purpose:'读取已选用的简历，并在申请职位时上传。',scopes:['个人简历 · v2 · PDF','联系邮箱','手机号码'],item:'resume'},
 {id:'token',title:'查看项目仓库',type:'凭据使用',agent:'Codex',time:'15:12',purpose:'查看仓库状态和待处理事项。',item:'github-token',scopes:['GitHub Token 使用'],binding:'GitHub Token → 子进程环境变量 GH_TOKEN',command:'gh repo view northstar/agent-skills'},
 {id:'fill',title:'登录任务管理',type:'焦点填充',agent:'Codex',time:'15:10',purpose:'在已打开的任务管理登录页填入密码。',item:'vikunja-password',scopes:['任务管理登录密码 · 焦点填充'],binding:'本机前台窗口的当前输入焦点'},
 {id:'organize',title:'整理自托管服务资料',type:'分类整理',agent:'Codex',time:'15:02',purpose:'按用途整理目录，补充生产环境和应用用途标签。',scopes:['Blinko 笔记 · 目录与标签','Vikunja 任务管理 · 目录与标签','SparkyFitness · 目录与标签']}
 ]}
function approvalsPage(){
 const data=requests(),r=data.find(r=>r.id===S.request)||data[0],done=D.decisions[r.id];
 const queue=data.filter(r=>(S.queueFilter==='all'||(S.queueFilter==='pending'?!D.decisions[r.id]:!!D.decisions[r.id]))&&(!S.queueQuery||(r.title+r.type).includes(S.queueQuery)));
 const type=r.id==='resume'?'普通文件交付':r.id==='organize'?'整理范围':'凭据使用方式';
 const explain=r.id==='server'||r.id==='token'?'由 CLI 创建子进程，在启动前注入凭据。Agent 只提供引用与命令，凭据原文不作为普通信息返回。':r.id==='resume'?'准备所选版本的临时文件副本供读取或上传。已经读到或上传的内容，不能通过撤销授权收回。':r.id==='fill'?'Agent 先定位输入框，再调用 CLI 发起本机填充；软件核对前台焦点并填写。工具自己的 DOM 焦点不等同于系统输入焦点。':'只允许查看获准资料的元数据，并自动调整目录与标签；不读取字段值，不修改正文。';
 return '<div class="queue-workspace"><aside class="queue-sidebar"><header><h1>访问审批</h1><p>'+data.filter(r=>!D.decisions[r.id]).length+' 条待处理</p><div class="search">'+icon('search')+'<input id="queue-search" value="'+e(S.queueQuery)+'" placeholder="搜索请求" aria-label="搜索请求"></div><div class="tabs compact">'+[['pending','待处理'],['all','全部'],['done','已处理']].map(([id,n])=>'<button class="tab '+(S.queueFilter===id?'active':'')+'" data-queue-filter="'+id+'">'+n+'</button>').join('')+'</div></header><div class="scroll">'+queue.map(x=>'<button class="queue-item '+(x.id===r.id?'selected':'')+'" data-request="'+x.id+'"><small>'+x.agent+'<span>'+x.time+'</span></small><h3>'+x.title+'</h3><p>'+x.type+'<span>'+ (D.decisions[x.id]?.result||'待处理')+'</span></p></button>').join('')+(queue.length?'':'<p class="empty-inline">没有匹配的请求。</p>')+'</div><footer>'+btn('请求设置','data-setting="records"','quiet small')+'</footer></aside><main class="queue-main scroll"><div id="page-error" class="form-error" hidden></div><article class="approval-card"><section class="approval-content"><div class="row spread">'+pill(done?.result||'待处理',done?'green':'amber')+'<span class="muted small">'+r.agent+' · 当前会话</span></div><h1>'+r.title+'</h1><p class="body-copy">'+r.purpose+'</p><p class="muted small">聊天名称和用途由 Agent 自述，仅供判断。</p><section class="content-section"><h2>申请范围</h2>'+r.scopes.map((label,n)=>'<label class="check-row"><input data-scope="'+n+'" type="checkbox" '+(S.scopes[r.id][n]?'checked':'')+' '+(done?'disabled':'')+'><span>'+label+'</span></label>').join('')+'</section><section class="content-section"><div class="row"><h2>'+type+'</h2>'+btn(icon('info'),'data-tip="'+r.id+'" aria-label="了解使用流程"','quiet icon-only')+'</div>'+(r.binding?'<div class="binding"><span>注入位置</span><strong>'+e(r.binding)+'</strong></div>':'')+(r.command?'<div class="command-block"><label>由 CLI 启动</label><code>'+e(r.command)+'</code></div>':'')+'<p class="body-copy">'+explain+'</p></section>'+(r.item?btn('查看关联资料 '+icon('arrow'),'data-item="'+r.item+'"','quiet'):'')+'</section><aside class="decision-panel"><h2>'+(done?'本次决定':'本次授权')+'</h2>'+(done?'<p class="decision-status">'+done.result+'</p><p>'+e(done.ttl)+'</p>'+btn('查看授权历史','data-history-request="'+r.id+'"','primary'):'<p><span id="selected-count" class="decision-number">'+S.scopes[r.id].filter(Boolean).length+'</span> / '+r.scopes.length+' 项</p><label class="control-label">授权期限</label>'+btn(S.ttl+icon('down'),'data-menu="ttl" id="ttl-button"')+'<p class="muted small">仅当前会话有效；批准范围内可重复使用。</p>'+btn('批准所选范围','data-action="approve"','primary')+btn('拒绝申请','data-action="deny"','quiet'))+'</aside></article></main></div>';
}
function approvalDecision(action){
 const r=requests().find(r=>r.id===S.request),approved=action==='approve';if(approved&&!S.scopes[r.id].some(Boolean))return;
 if(mutate(next=>{next.decisions[r.id]={result:approved?'已批准':'已拒绝',ttl:S.ttl,scopes:clone(S.scopes[r.id])};next.history.unshift({id:'request-'+r.id,title:r.title,type:r.type,state:approved?'有效':'已拒绝',agent:r.agent,time:'刚刚',ttl:S.ttl,item:r.item,scope:r.scopes.filter((_,n)=>S.scopes[r.id][n]),events:[['刚刚',approved?'批准所选范围；尚无访问事件':'拒绝申请']]})})){render();toast(approved?'已记录授权决定':'已拒绝申请')}
}
function proposalsPage(){
 const p=D.proposals.find(p=>p.id===S.proposal)||D.proposals[0],list=D.proposals.filter(p=>S.proposalFilter==='all'||(S.proposalFilter==='pending'?p.status==='待确认':p.status!=='待确认'));
 let body='';
 if(p.id==='import')body='<section class="proposal-paper"><div class="row spread"><h2>'+e(p.name)+'</h2>'+pill(p.template)+'</div><p class="muted small">'+e(directoryName(p.directory))+'</p><div class="facts">'+p.fields.map(([k,v])=>'<div class="fact"><label>'+e(k)+'</label><strong>'+e(v)+'</strong></div>').join('')+'</div><div class="row">'+p.tags.map(t=>pill(t)).join('')+'</div><div class="relation-note">'+icon('link')+'部署在：Azure 日本服务器</div></section>';
 if(p.id==='update')body='<div class="diff-summary"><h2>阿里云杭州服务器</h2><p>字段：SSH 端口</p><div class="diff-columns"><div><label>当前内容</label><strong>'+p.before+'</strong></div><div><label>提案内容</label><strong>'+p.after+'</strong></div></div><p class="muted small">只有列出的字段会被修改；目录、标签及凭据关联保持原样。</p></div>';
 if(p.id==='organized')body='<div class="notice">'+icon('check')+'已依据先前的整理授权自动应用，无需再次确认。</div><section class="content-section"><h2>已完成的调整</h2>'+p.items.map(id=>'<div class="manage-row"><span class="grow">'+e(byId(id)?.name)+'</span><span class="muted small">目录：自托管服务</span>'+pill('生产环境')+'</div>').join('')+'</section>'+btn('查看整理授权','data-history="grant-org"','quiet');
 return '<div class="queue-workspace"><aside class="queue-sidebar"><header><h1>录入提案</h1><p>核对新增与变更，查看整理结果</p><div class="tabs compact">'+[['all','全部'],['pending','待确认'],['done','已处理']].map(([id,n])=>'<button class="tab '+(S.proposalFilter===id?'active':'')+'" data-proposal-filter="'+id+'">'+n+'</button>').join('')+'</div></header><div class="scroll">'+list.map(x=>'<button class="queue-item '+(x.id===p.id?'selected':'')+'" data-proposal="'+x.id+'"><small>'+x.type+'<span>'+x.status+'</span></small><h3>'+x.title+'</h3><p>'+x.agent+'<span>'+x.time+'</span></p></button>').join('')+'</div></aside><main class="queue-main scroll"><div class="proposal-content"><div id="page-error" class="form-error" hidden></div><header><div class="row spread">'+pill(p.status,p.status==='待确认'?'amber':'green')+'<span class="muted small">'+p.agent+' · '+p.time+'</span></div><h1>'+p.title+'</h1><p>'+p.summary+'</p></header>'+body+'<footer class="proposal-actions">'+(p.status==='待确认'?btn('拒绝提案','data-proposal-decision="reject"','quiet')+btn('编辑提案','data-action="edit-proposal"')+btn(p.id==='import'?'确认入库':'确认修改','data-proposal-decision="accept"','primary'):p.status==='已拒绝'?'<p class="muted">未修改信息库。</p>':p.id!=='organized'?btn('查看资料 '+icon('arrow'),'data-item="'+(p.item||'proposal-record')+'"','primary'):'')+'</footer></div></main></div>';
}
function historyPage(){
 const rows=D.history.filter(h=>(S.historyFilter==='all'||(S.historyFilter==='active'?h.state==='有效':h.state!=='有效'))&&(S.historyType==='all'||h.type===S.historyType));
 const h=rows.find(h=>h.id===S.historyId)||rows[0];
 return '<div class="history-workspace"><section class="history-list-pane"><header><div class="row spread"><div><h1>授权历史</h1><p class="muted">查看批准范围、重复使用与结束原因</p></div>'+btn('记录设置','data-setting="records"','quiet')+'</div><div class="row spread"><nav class="tabs">'+[['all','全部'],['active','有效'],['ended','已结束']].map(([id,n])=>'<button class="tab '+(S.historyFilter===id?'active':'')+'" data-history-filter="'+id+'">'+n+'</button>').join('')+'</nav>'+btn(S.historyType==='all'?'所有类型':S.historyType,'data-xmenu="history-type"','small')+'</div></header><div class="history-table scroll"><div class="history-table-head"><span>请求与用途</span><span>状态</span><span>时间</span></div>'+rows.map(x=>'<button class="history-row '+(h?.id===x.id?'selected':'')+'" data-history="'+x.id+'"><span><strong>'+x.title+'</strong><small>'+x.type+' · '+x.agent+'</small></span><span>'+pill(x.state,x.state==='有效'?'green':'')+'</span><span>'+x.time+'</span></button>').join('')+(rows.length?'':'<div class="empty">没有匹配的记录。</div>')+'</div></section><aside class="history-detail scroll">'+(h?'<div id="page-error" class="form-error" hidden></div><div class="row spread">'+pill(h.state,h.state==='有效'?'green':'')+'<span class="muted small">'+h.ttl+'</span></div><h2>'+h.title+'</h2><p class="muted">'+h.agent+'</p><section class="content-section"><h3>批准范围</h3><ul class="scope-list">'+h.scope.map(s=>'<li>'+e(s)+'</li>').join('')+'</ul></section><section class="content-section"><h3>访问与使用事件</h3><div class="event-timeline">'+h.events.map(([t,x])=>'<div><small>'+t+'</small><p>'+x+'</p></div>').join('')+'</div></section><div class="history-actions">'+(h.item?btn('查看资料','data-item="'+h.item+'"'):'')+(h.state==='有效'?btn('撤销授权','data-revoke="'+h.id+'"'):'')+'</div>':'<div class="empty">选择一条授权记录</div>')+'</aside></div>';
}
function recyclePage(){
 return '<div class="full-page scroll"><header class="row spread"><div>'+btn('返回信息库','data-page="library"','quiet')+'<h1>回收站</h1><p class="muted">删除的资料保留 30 天；恢复资料不会恢复旧授权。</p></div></header><div id="page-error" class="form-error" hidden></div><div class="settings-card">'+(D.trash.length?D.trash.map(i=>'<div class="manage-row">'+graphic(i.kind)+'<div class="grow"><h3>'+e(i.name)+'</h3><p class="muted small">'+e(directoryName(i.directory))+' · 删除于 '+i.deletedAt+'</p></div>'+btn('查看','data-trash-preview="'+i.id+'"','quiet')+btn('恢复','data-restore-item="'+i.id+'"')+'</div>').join(''):'<div class="empty">回收站为空</div>')+'</div></div>';
}

function pluginDetail(p){
 if(!p)return '<div class="empty"><h2>此模板插件未安装</h2><p>已有资料可继续在通用视图查看；重新安装同一插件后，可恢复专用展示。</p>'+btn('安装插件包','data-action="install"','primary')+'</div>';
 const panels=pluginPanels(p);if(S.pluginTab==='settings'&&!panels.length)S.pluginTab='overview';
 const t=p.templates[0],count=D.items.filter(i=>i.packageId===p.id).length,update=p.id==='builtin.server'&&p.version==='1.0.0';
 let html='<div class="plugin-detail-head">'+graphic(t.icon==='layers'?'service':t.icon)+'<div class="grow"><div class="row"><h1>'+e(p.name)+'</h1>'+pill(p.enabled?'已启用':'已停用',p.enabled?'green':'')+'</div><p>'+e(p.description)+'</p><div class="plugin-meta">'+e(p.author)+' · '+e(p.origin||'本地安装')+' · v'+p.version+'</div></div>'+btn(p.enabled?'停用':'启用','data-toggle-plugin="'+p.id+'"',p.enabled?'':'primary')+'</div>';
 html+='<div class="plugin-facts"><div><span>提供模板</span><strong>'+p.templates.length+' 个</strong></div><div><span>已用于</span><button class="text-link" data-plugin-records="'+p.id+'">'+count+' 项资料 '+icon('arrow')+'</button></div><div><span>目录归属</span><strong>由每份资料自行选择</strong></div></div>';
 if(update)html+='<div class="update-line">'+icon('download')+'<span class="grow"><strong>v1.1.0 可用</strong><small>新增可选的维护负责人，已有资料保持原样。</small></span>'+btn('查看更新','data-action="update"','small')+'</div>';
 html+='<nav class="tabs">'+[['overview','模板预览'],['structure','字段与关联'],['agent','Agent 录入说明'],...(panels.length?[['settings','插件设置']]:[])].map(([id,label])=>'<button class="tab '+(S.pluginTab===id?'active':'')+'" data-plugin-tab="'+id+'">'+label+'</button>').join('')+'</nav>';
 if(S.pluginTab==='settings'){html+=pluginSettings(p)}else if(S.pluginTab==='overview'){
  html+='<div class="row spread"><h2>'+e(t.name)+'</h2>'+btn('用这个模板添加','data-new-template="'+t.id+'" '+(p.enabled?'':'disabled'),'primary')+'</div><p class="muted small" style="margin:9px 0 20px">按下方结构填写，目录和关联可以稍后补充。</p><div class="template-sheet">'+templatePreview(t)+'</div>';
 }else if(S.pluginTab==='structure'){
  html+='<h2>信息字段</h2><div class="definition-list">'+t.fields.map(f=>'<div><strong>'+e(f.label)+'</strong><span>'+e(({text:'文字',url:'链接',number:'数字',date:'日期',multiline:'长文本',entries:'多段经历'})[f.type])+'</span><span>'+(f.required?'必填':'选填')+'</span></div>').join('')+'</div><h2 style="margin-top:26px">可选关联</h2>'+t.relations.map(r=>'<div class="definition-relation">'+icon('link')+'<span>'+e(r.label)+'</span><span class="grow"></span><small>'+(r.targetTemplates.length?'关联已有 '+e(r.targetTemplates.join(' / ')).replace('server','服务器'):'关联已有资料')+'</small></div>').join('');
 }else html+='<div class="agent-note"><div class="row">'+icon('file')+'<h2>随插件提供的说明</h2></div><p>'+e(t.instructions)+'</p><ol><li>先发现已安装模板，复用已有定义。</li><li>录入字段值之前按现有流程申请必要的访问授权。</li><li>提交录入提案，保留原始来源与明确的关联依据。</li></ol></div>';
 html+='<footer class="plugin-foot"><span>停用或移除插件，已有资料仍可在通用视图中查看。</span>'+(p.origin==='内置'?'':btn('移除插件','data-remove-plugin="'+p.id+'"','quiet'))+'</footer>';
 return html;
}

/* Host-owned capability panels. Plugin packages do not execute settings code. */
function pluginPanels(p){
 return p?.id==='builtin.server'?[{id:'ssh-trust',title:'SSH 主机信任'}]:[];
}
function hostEndpoint(i){
 return {host:i.values?.host||'',port:String(i.values?.port||'22')};
}
function hostIdentityKey(i){
 const {host,port}=hostEndpoint(i);return JSON.stringify([host,port]);
}
function hostFingerprint(i){
 const known={azure:['tokyo.beichen.example','2222','SHA256:DemoTokyoHostFingerprint'],aliyun:['hangzhou.beichen.example','22','SHA256:DemoHangzhouHostFingerprint']};
 const sample=known[i.id],ep=hostEndpoint(i);
 return sample&&sample[0]===ep.host&&sample[1]===ep.port?sample[2]:null;
}
function isHostTrusted(i){
 const fp=hostFingerprint(i);return !!fp&&D.hostTrust?.[hostIdentityKey(i)]===fp;
}
function serverTrustLink(i){
 return i.packageId==='builtin.server'?btn(icon('shield')+'主机身份 · '+(isHostTrusted(i)?'已信任':'未核对')+icon('chevron'),'data-host-item="'+e(i.id)+'"','quiet small host-identity-link'):'';
}
function pluginSettings(p){
 const servers=liveItems().filter(i=>i.packageId===p.id&&i.templateId==='server');
 return '<section class="plugin-settings"><header class="plugin-settings-heading"><div><h2>SSH 主机信任</h2><p>核对主机指纹，确认连接的是预期服务器。</p></div>'+btn('导入 known_hosts','data-preview="import-hosts" '+(p.enabled?'':'disabled'),'small')+'</header>'+(!p.enabled?'<div class="notice">'+icon('info')+'插件已停用。已有记录仍可查看和撤销；重新确认信任前请先启用插件。</div>':'')+'<div class="host-trust-list">'+(servers.length?servers.map(i=>{const ep=hostEndpoint(i);return '<div class="host-trust-row">'+graphic('server')+'<div class="grow"><strong>'+e(i.name)+'</strong><p class="mono">'+e(ep.host||'未填写地址')+':'+e(ep.port)+'</p></div>'+pill(isHostTrusted(i)?'已信任':'未核对',isHostTrusted(i)?'green':'amber')+btn('查看','data-host-item="'+e(i.id)+'"','quiet small')+'</div>'}).join(''):'<div class="empty"><h3>还没有服务器资料</h3><p>添加服务器后，可在这里核对主机身份。</p>'+btn('添加服务器','data-new-template="server" '+(p.enabled?'':'disabled'),'primary')+'</div>')+'</div><div class="quiet-note">'+icon('shield')+'主机信任用于核对服务器身份；使用登录凭据仍需单独授权。</div></section>';
}
function hostDialog(id){
 const i=byId(id);if(!i)return;const ep=hostEndpoint(i),fp=hostFingerprint(i),trusted=isHostTrusted(i),enabled=packageById(i.packageId)?.enabled;
 S.hostItem=id;
 const action=fp&&(trusted||enabled)?btn(trusted?'撤销信任':'确认信任','data-confirm-host="'+e(id)+'"',trusted?'':'primary'):'';
 modal('主机身份 · '+i.name,'<div id="form-error" class="form-error" hidden></div><div class="row spread"><span class="muted small">服务器信息 · SSH 主机信任</span>'+pill(trusted?'已信任':'未核对',trusted?'green':'amber')+'</div><div class="facts"><div class="fact"><label>主机地址</label><strong>'+e(ep.host||'未填写')+'</strong></div><div class="fact"><label>SSH 端口</label><strong>'+e(ep.port)+'</strong></div></div>'+(fp?'<div class="host-fingerprint"><label>ED25519 指纹</label><code>'+e(fp)+'</code></div><p class="body-copy host-explanation">'+(trusted?'已确认此地址与端口的主机指纹。撤销后，后续连接需要重新核对。':'请通过服务器控制台或其他可信渠道核对上述指纹，再确认信任。')+'</p>':'<div class="notice">尚未取得这个地址与端口的主机指纹。首次连接或导入主机记录后，再进行核对。</div>')+(!enabled&&!trusted?'<p class="muted small host-explanation">服务器插件已停用，请先启用再确认信任。</p>':'')+'<div class="host-dialog-links">'+btn('查看服务器资料','data-open-host-record="'+e(id)+'"','quiet small')+btn('管理全部主机信任 '+icon('arrow'),'data-plugin-settings="builtin.server"','quiet small')+'</div>',btn('关闭','data-action="close"')+action);
}

document.addEventListener('click',ev=>{
 const t=ev.target.closest('button,a');if(!t)return;
 if(t.dataset.page){closeModal();S.page=t.dataset.page;document.body.classList.remove('reading-mode');render()}
 if(t.dataset.dir){S.dir=t.dataset.dir;S.query='';S.filter='all';S.tag='';S.detailTab='overview';S.selected=filtered()[0]?.id;render()}
 if(t.dataset.content){S.dir='all';S.query='';S.filter=t.dataset.content;S.tag='';S.selected=filtered()[0]?.id;render()}
 if(t.dataset.item)goItem(t.dataset.item);
 if(t.dataset.detailTab){S.detailTab=t.dataset.detailTab;renderDetail()}
 if(t.dataset.version){S.fileVersion=t.dataset.version;renderDetail()}
 if(t.dataset.package){S.page='settings';S.setting='plugins';S.plugin=t.dataset.package;S.pluginTab='overview';document.body.classList.remove('reading-mode');render()}
 if(t.dataset.pluginTab){S.pluginTab=t.dataset.pluginTab;render()}
 if(t.dataset.pluginFilter){S.pluginFilter=t.dataset.pluginFilter;render()}
 if(t.dataset.pluginRecords){S.page='library';S.dir='all';S.query='';S.tag='';S.filter=packageById(t.dataset.pluginRecords).templates[0].id;S.selected=filtered()[0]?.id;render()}
 if(t.dataset.togglePlugin){if(mutate(next=>{const p=next.plugins.find(p=>p.id===t.dataset.togglePlugin);p.enabled=!p.enabled})){render();toast(packageById(t.dataset.togglePlugin).enabled?'插件已启用':'插件已停用，资料已保留')}}
 if(t.dataset.removePlugin){if(mutate(next=>next.plugins=next.plugins.filter(p=>p.id!==t.dataset.removePlugin))){S.plugin=D.plugins[0]?.id;render();toast('插件已移除，资料仍保留在信息库')}}
 if(t.dataset.newTemplate)startForm(t.dataset.newTemplate);
 if(t.dataset.addEntry){collectDraft();draft.values[t.dataset.addEntry]??=[];draft.values[t.dataset.addEntry].push({});form()}
 if(t.dataset.menu||t.dataset.relationMenu){showMenu(t);return}
 if(t.dataset.filter){S.filter=t.dataset.filter;S.selected=filtered()[0]?.id;hideMenu();renderList();renderDetail();document.getElementById('filter-button').focus()}
 if(t.dataset.pickDirectory){draft.directory=t.dataset.pickDirectory;hideMenu();const b=document.getElementById('directory-choice');b.innerHTML=icon('folder')+e(directoryName(draft.directory))+icon('down');b.focus()}
 if(t.hasAttribute('data-pick-relation')){const key=t.dataset.key,id=t.dataset.pickRelation;draft.relations[key]??=[];draft.relations[key]=!id?[]:draft.relations[key].includes(id)?draft.relations[key].filter(x=>x!==id):[...draft.relations[key],id];hideMenu();form();document.querySelector('[data-relation-menu="'+key+'"]')?.focus()}
 if(t.dataset.request){S.request=t.dataset.request;if(S.request==='organize'&&S.ttl==='1 小时')S.ttl='30 分钟';render()}
 if(t.dataset.ttl){S.ttl=t.dataset.ttl;hideMenu();document.getElementById('ttl-button').innerHTML=e(S.ttl)+icon('down')}
 switch(t.dataset.action){
 case 'new':chooser();break;
 case 'edit':editSelected();break;
 case 'close':closeModal();break;
 case 'clear':S.query='';S.filter='all';S.tag='';S.selected=filtered()[0]?.id;render();break;
 case 'expand':document.body.classList.toggle('reading-mode');t.setAttribute('aria-label',document.body.classList.contains('reading-mode')?'退出展开阅读':'展开阅读');break;
 case 'install':pending=null;packageErrors=[];installDialog();break;
 case 'sample-package':pending=clone(MODEL.domainPackage);packageErrors=validatePackage(pending);installDialog();break;
 case 'install-package':installPackage();break;
 case 'agent-brief':agentBrief();break;
 case 'copy-brief':{const prompt='请为知予制作一个模板插件包。需求：'+document.getElementById('brief').value+'\n先检查并复用已安装模板；提供字段、布局、可选关联、Agent 录入说明和虚构示例。模板不决定目录，不直接读写私密资料，不自动迁移已有信息。请按本轮原型规范制作 JSON：'+new URL('plugin-spec.md',location.href).href; navigator.clipboard.writeText(prompt).then(()=>{t.textContent='已复制，可以粘贴给 Agent';t.classList.add('copied')}).catch(()=>{const err=document.getElementById('copy-error');err.hidden=false;err.textContent='剪贴板不可用，请选中下方说明复制。';err.insertAdjacentHTML('beforeend','<textarea readonly>'+e(prompt)+'</textarea>')});break}
 case 'update':updateDialog();break;
 case 'apply-update':if(mutate(next=>{const p=next.plugins.find(p=>p.id==='builtin.server');p.version='1.1.0';p.templates[0].fields.push({key:'maintainer',label:'维护负责人',type:'text',required:false});p.templates[0].sections[0].keys.push('maintainer')})){closeModal();render();toast('已更新至 v1.1.0；已有资料未改动')}break;
 case 'new-directory':modal('新建目录','<form id="directory-form"><div id="form-error" class="form-error" hidden></div><div class="input-field"><label for="dir-name">目录名称</label><input id="dir-name" required maxlength="50" placeholder="例如：北辰项目"></div><p class="muted">目录按用途组织，可以放入不同模板的资料。</p></form>',btn('取消','data-action="close"')+'<button class="btn primary" type="submit" form="directory-form">创建目录</button>');break;
 case 'approve':case 'deny':approvalDecision(t.dataset.action);break;
 }
});
document.addEventListener('input',ev=>{if(ev.target.id==='search'){S.query=ev.target.value;const list=filtered();if(!list.some(i=>i.id===S.selected))S.selected=list[0]?.id;renderList();renderDetail()}});
document.addEventListener('change',async ev=>{
 if(ev.target.id==='package-file'){const file=ev.target.files[0];if(!file)return;try{if(file.size>1024*1024)throw Error('插件包超过 1 MB。');pending=JSON.parse(await file.text());packageErrors=validatePackage(pending);if(!pending||typeof pending!=='object'||Array.isArray(pending))throw Error('插件包必须是 JSON 对象。');installDialog()}catch(err){const el=document.getElementById('install-error');el.hidden=false;el.textContent=err instanceof SyntaxError?'无法解析插件包，请选择有效的 JSON 文件。':err.message}}
 if(ev.target.hasAttribute('data-scope')){S.scopes[S.request][Number(ev.target.dataset.scope)]=ev.target.checked;const n=S.scopes[S.request].filter(Boolean).length;document.getElementById('selected-count').textContent=n;document.querySelector('[data-action="approve"]').disabled=!n}
});
document.addEventListener('submit',ev=>{
 if(ev.target.id==='record-form'){ev.preventDefault();saveRecord()}
 if(ev.target.id==='directory-form'){ev.preventDefault();const name=document.getElementById('dir-name').value.trim();if(!name)return;if(D.dirs.some(d=>d.name===name)){const err=document.getElementById('form-error');err.hidden=false;err.textContent='已有同名目录，请换一个名称。';return}const id='dir-'+crypto.randomUUID();if(mutate(next=>next.dirs.push({id,name,icon:'folder'}))){closeModal();S.page='library';S.dir=id;S.query='';S.filter='all';S.selected=null;render()}}
});
document.addEventListener('keydown',ev=>{
 if(ev.key==='Escape'){if(document.querySelector('.floating-menu')){hideMenu();menuTrigger?.focus()}else if(document.querySelector('.modal'))closeModal();else document.body.classList.remove('reading-mode')}
 if((ev.ctrlKey||ev.metaKey)&&ev.key==='k'){ev.preventDefault();document.getElementById('search')?.focus()}
 if(document.querySelector('.floating-menu')&&['ArrowDown','ArrowUp'].includes(ev.key)){ev.preventDefault();const buttons=[...document.querySelectorAll('.floating-menu button')],at=buttons.indexOf(document.activeElement);buttons[(at+(ev.key==='ArrowDown'?1:-1)+buttons.length)%buttons.length]?.focus()}
 if(ev.key==='Tab'&&document.querySelector('.modal')&&!document.querySelector('.floating-menu')){const f=[...document.querySelectorAll('.modal button,.modal input,.modal textarea,.modal a,.modal summary')].filter(el=>!el.disabled&&el.offsetParent!==null);if(ev.shiftKey&&document.activeElement===f[0]){ev.preventDefault();f.at(-1)?.focus()}else if(!ev.shiftKey&&document.activeElement===f.at(-1)){ev.preventDefault();f[0]?.focus()}}
});
document.addEventListener('click',ev=>{if(document.querySelector('.floating-menu')&&!ev.target.closest('.floating-menu,[data-menu],[data-relation-menu],[data-xmenu]'))hideMenu()});
window.addEventListener('resize',hideMenu);document.addEventListener('scroll',ev=>{if(document.querySelector('.floating-menu')&&!ev.target.closest?.('.floating-menu')&&menuTrigger&&ev.target.contains?.(menuTrigger))positionMenu()},true);
// Preserve earlier prototype choices while giving each endpoint its own trust record.
if(!D.hostTrust){D.hostTrust={};const i=byId('azure');if(i&&D.hostTrusted!==false&&hostFingerprint(i))D.hostTrust[hostIdentityKey(i)]=hostFingerprint(i)}
D.plugins.filter(p=>p.id.startsWith('builtin.')&&p.author==='信息'+'授权').forEach(p=>p.author='知予');
paths.sort='M8 4v16m-4-4 4 4 4-4M14 5h6m-6 5h4m-4 5h2';
paths.settings=paths.sliders;paths.trash='M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7m4-7v7';paths.more='M5 12h.01M12 12h.01M19 12h.01';paths.edit='m15 4 5 5M4 16 16 4a2 2 0 0 1 4 4L8 20H4v-4Z';
Object.assign(S.scopes,{token:[true],fill:[true],organize:[true,true,true]});
for(const [id,d] of Object.entries(D.decisions))if(S.scopes[id])S.scopes[id]=clone(d.scopes);
function xMenu(t){
 const name=t.dataset.xmenu;let html='';
 const option=(label,attrs)=>'<button '+attrs+'>'+e(label)+'</button>';
 const choice=(label,attrs,chosen)=>'<button '+attrs+' role="menuitemradio" aria-checked="'+chosen+'"><span class="grow">'+e(label)+'</span>'+(chosen?icon('check'):'')+'</button>';
 if(name==='type')html=[['all','全部类型'],...typeChoices()].map(([id,label])=>choice(label,'data-simple-type="'+e(id)+'"',S.filter===id)).join('');
 if(name==='tag')html=[['','全部标签'],...D.tags.map(t=>[t,t])].map(([id,label])=>choice(label,'data-simple-tag="'+e(id)+'"',S.tag===id)).join('');
 if(name==='group')html=['none','template','directory'].map(g=>choice(groupName(g),'data-group="'+g+'"',S.groupBy===g)).join('');
 if(name==='sort')html=[['updated','最近更新优先'],['name','按名称']].map(([id,label])=>choice(label,'data-sort="'+id+'"',S.sort===id)).join('');
 if(name==='setting-wait')html=['5 分钟','15 分钟','30 分钟','1 小时','2 小时'].map(v=>option(v,'data-setting-value="'+v+'" data-key="wait"')).join('');
 if(name==='setting-retention')html=['30 天','90 天','180 天','365 天'].map(v=>option(v,'data-setting-value="'+v+'" data-key="retention"')).join('');
 if(name==='history-type')html=['all',...new Set(D.history.map(h=>h.type))].map(v=>option(v==='all'?'所有类型':v,'data-history-type="'+v+'"')).join('');
 if(name==='record'){const i=selected();html=option('编辑资料','data-action="edit"')+option('移动到其他目录','data-action="move-record"')+option('修改标签','data-action="edit-tags"')+option('查看内容版本','data-action="revisions"')+(i.templateId?option('查看模板定义','data-package="'+i.packageId+'"'):'')+option('移入回收站','data-action="delete-record"');}
 menu(t,html);
}
function showSimpleForm(title,label,value,kind,identity=''){
 modal(title,'<form id="simple-form" data-kind="'+kind+'" data-identity="'+e(identity)+'"><div id="form-error" class="form-error" hidden></div><div class="input-field"><label for="simple-value">'+label+'</label><input id="simple-value" value="'+e(value)+'" required maxlength="120"></div></form>',btn('取消','data-action="close"')+'<button class="btn primary" form="simple-form" type="submit">保存</button>');
}
function coreForm(kind,editing=false){
 editId=editing?S.selected:null;const i=editing?selected():null;const labels={document:'文档',file:'普通文件',credential:'凭据'};
 modal((editing?'编辑':'添加')+labels[kind],'<form id="core-form" data-kind="'+kind+'"><div id="form-error" class="form-error" hidden></div><div class="input-field"><label for="core-name">名称</label><input id="core-name" required value="'+e(i?.name||'')+'" placeholder="用用途命名"></div><div class="input-field"><label for="core-desc">用途与内容说明</label><textarea id="core-desc" required rows="3" placeholder="说明用于什么、包含哪些信息，以及适用的工具或服务">'+e(i?.summary||'')+'</textarea></div>'+(kind==='document'?'<div class="input-field"><label for="core-body">正文</label><textarea id="core-body" rows="6">'+e(i?.values?.body||'')+'</textarea></div>':kind==='file'?'<div class="input-field"><label for="core-file">文件</label><input id="core-file" type="file" '+(editing?'':'required')+'><p class="muted small">文件原文和资料一起保存；版本替换保留原来的资料身份。</p></div>':'<div class="input-field"><label for="credential-value">Token 或密码</label><input id="credential-value" type="password" autocomplete="new-password" placeholder="输入新值；留空保留已有值"><p class="muted small">字符串通过环境变量或焦点填充使用，文件凭据通过临时路径注入。</p></div><div class="input-field"><label for="core-file">或选择凭据文件</label><input id="core-file" type="file"></div><div class="input-field"><label for="binding-name">注入引用名称</label><input id="binding-name" value="'+e(i?.binding||'SECRET_TOKEN')+'" required></div>')+'</form>',btn('取消','data-action="close"')+'<button class="btn primary" form="core-form" type="submit">保存资料</button>');
}
function editSelected(){const i=selected();if(['document','file','resume','credential'].includes(i.kind))coreForm(i.kind==='resume'?'file':i.kind,true);else startForm(i.templateId,true)}
function previewDialog(id){
 const descriptions={
 notification:['访问申请通知','<div class="notification-preview">'+icon('inbox')+'<div><strong>知予 · 新的访问申请</strong><p>Codex 请求使用凭据</p><small>打开应用查看请求范围</small></div></div>',btn('查看对应请求','data-preview-open-request="server"','primary')],
 backup:['创建加密备份','<ol class="step-list"><li>选择备份位置：包含信息、文件、凭据与模板定义。</li><li>校验整个备份容器，确认导出完成。</li><li>单独保存恢复密钥，不与备份文件放在一起。</li></ol><p class="muted">确认前显示资料数量、附件体积与目标路径。</p>',btn('查看确认界面','data-preview="backup-confirm"','primary')],
 'backup-confirm':['确认备份范围','<div class="facts"><div class="fact"><label>信息库</label><strong>'+D.items.length+' 项资料</strong></div><div class="fact"><label>包含内容</label><strong>普通文件、托管凭据、目录、标签、模板定义</strong></div></div><p class="body-copy">下一步由系统文件选择器指定加密备份的位置，并提示单独保存恢复密钥。</p>',''],
 restore:['从备份恢复','<div class="input-field"><label>加密备份文件</label><input type="file"></div><div class="input-field"><label>恢复密钥</label><input type="password" autocomplete="off" placeholder="粘贴恢复密钥"></div><p class="muted">校验通过后预览恢复内容，再确认是否替换当前库。恢复不会自动恢复活动授权。</p>',btn('查看校验后的预览','data-preview="restore-confirm"')],
 'restore-confirm':['恢复内容预览','<p class="body-copy">备份时间、内容数量、文件容量和模板兼容性会列在此处。确认恢复前，先为当前资料创建备份。</p><div class="notice">恢复将替换当前库内容，活动授权结束。缺少插件时保留通用展示。</div>',''],
 'recovery-key':['恢复密钥的保管','<p class="body-copy">备份使用独立恢复密钥加密。将密钥保存在你能找回的安全位置。恢复时同时需要备份文件和对应密钥。</p>',''],
 materials:['临时凭据材料','<div class="manage-row"><span class="grow">检查反向代理服务</span>'+pill('执行中','green')+'</div><p class="body-copy">SSH 私钥临时文件保留至进程组结束。已结束任务的材料检查、清理失败及重试结果在这里显示。</p>',''],
 attachments:['普通附件维护','<div class="manage-row"><span class="grow">个人简历 · v2 副本</span>'+pill('授权有效','green')+'</div><p class="body-copy">授权到期后尝试回收副本。占用或身份核查失败时保留登记，显示原因并允许重试。</p>',''],
 quit:['完全退出应用','<p class="body-copy">停止本机服务，结束当前会话授权；先保存资料，再结束进程。</p><p class="muted">保存失败时保留窗口与内容，允许重试。</p>',''],
 'import-hosts':['导入 SSH 主机记录','<div class="input-field"><label>known_hosts 文件</label><input type="file"></div><p class="body-copy">导入后先预览主机、端口与指纹，逐项确认。已有记录冲突时保留双方内容以供核对。</p>',''],
 'agent-connect':['Agent 接入流程','<ol class="step-list"><li>安装受管理的访问 Skill 与配套 CLI。</li><li>通过宿主的信任入口确认会话 hooks。</li><li>新会话自动关联，查询目录后再发起访问申请。</li></ol><p class="muted">不会在页面显示私密会话关联值。</p>',''],
 'agent-rules':['Agent 录入与整理约定','<ol class="step-list"><li>先查已有资料与模板，避免重复录入。</li><li>目录按保留用途选择，不照着模板名称自动建目录。</li><li>标签用于跨目录检索；优先复用已有标签。</li><li>模板字段记录有明确含义的信息，例如运行环境、地区。</li><li>关联必须有来源依据；无法确认时留空。</li><li>模板缺失时可制作插件包，安装与资料入库分别确认。</li></ol>','']
 };
 const d=descriptions[id];if(d)modal(d[0],d[1],btn('关闭','data-action="close"')+d[2]);
}
document.addEventListener('click',ev=>{
 const t=ev.target.closest('button,a');if(!t)return;
 if(t.dataset.hostItem){hostDialog(t.dataset.hostItem);return}
 if(t.dataset.openHostRecord){closeModal();goItem(t.dataset.openHostRecord);return}
 if(t.dataset.pluginSettings){closeModal();S.page='settings';S.setting='plugins';S.plugin=t.dataset.pluginSettings;S.pluginTab='settings';render();return}
 if(t.dataset.confirmHost){const i=byId(t.dataset.confirmHost);if(!i)return;const key=hostIdentityKey(i),fp=hostFingerprint(i),trusted=isHostTrusted(i);if(!fp||(!trusted&&!packageById(i.packageId)?.enabled))return;if(mutate(n=>{if(trusted)delete n.hostTrust[key];else n.hostTrust[key]=fp})){closeModal();render();toast(trusted?'已撤销主机信任':'已确认主机身份')}return}
 if(t.dataset.setting){closeModal();S.page='settings';S.setting=t.dataset.setting;render()}
 if(t.dataset.tag){S.page='library';S.tag=S.tag===t.dataset.tag?'':t.dataset.tag;S.selected=filtered()[0]?.id;render()}
 if(t.dataset.xmenu){xMenu(t);return}
 if(t.hasAttribute('data-simple-type')||t.hasAttribute('data-simple-tag')){if(t.hasAttribute('data-simple-type'))S.filter=t.dataset.simpleType;else S.tag=t.dataset.simpleTag;S.selected=filtered()[0]?.id;render()}
 if(t.dataset.group){S.groupBy=t.dataset.group;hideMenu();renderList()}
 if(t.dataset.sort){S.sort=t.dataset.sort;hideMenu();renderList()}
 if(t.dataset.theme){if(mutate(n=>n.settings.theme=t.dataset.theme)){render();toast('已切换为'+(t.dataset.theme==='dark'?'黑暗':'明亮')+'主题')}}
 if(t.dataset.toggleSetting){if(mutate(n=>n.settings[t.dataset.toggleSetting]=!n.settings[t.dataset.toggleSetting]))render()}
 if(t.dataset.settingValue){const k=t.dataset.key,v=t.dataset.settingValue;if(k==='retention'&&parseInt(v)<parseInt(D.settings[k]))modal('缩短记录保留期限','<p class="body-copy">改为 '+v+' 后，将清理超出期限的授权与访问记录。资料内容与回收站不受影响。</p><div id="form-error" class="form-error" hidden></div>',btn('取消','data-action="close"')+btn('确认调整','data-confirm-retention="'+v+'"','primary'));else if(mutate(n=>n.settings[k]=v)){render();toast('设置已保存')}}
 if(t.dataset.confirmRetention){if(mutate(n=>n.settings.retention=t.dataset.confirmRetention)){closeModal();render();toast('记录保留期限已更新')}}
 if(t.dataset.renameDir)showSimpleForm('重命名目录','目录名称',directoryName(t.dataset.renameDir),'directory',t.dataset.renameDir);
 if(t.dataset.renameTag)showSimpleForm('重命名标签','标签名称',t.dataset.renameTag,'tag',t.dataset.renameTag);
 if(t.dataset.preview)previewDialog(t.dataset.preview);
 if(t.dataset.previewOpenRequest){closeModal();S.page='approvals';S.request=t.dataset.previewOpenRequest;S.queueFilter='all';render()}
 if(t.dataset.tip){const r=requests().find(r=>r.id===t.dataset.tip);modal('这次授权如何使用','<p class="body-copy">'+(r.id==='resume'?'申请文件 → 批准指定版本 → CLI 领取临时副本 → Agent 读取或上传。普通文件与凭据文件有不同的交付边界。':r.id==='fill'?'申请焦点填充 → 批准凭据与有效期 → Agent 定位输入框 → CLI 请求本机填充。只能作用于真实系统焦点；页面回读与截图仍可能暴露已填入内容。':r.id==='organize'?'申请固定资料集合 → 批准元数据整理 → Agent 自动应用目录与标签 → 留下结果记录。此授权不包含字段值。':'申请凭据与注入方式 → 审批 → Agent 调用 CLI 并提供命令 → CLI 创建子进程并注入。不会把密钥放进 Agent 的全局环境。')+'</p><p class="muted">只在当前会话和有效期内复用；变更凭据或使用方式需要重新申请。</p>',btn('明白了','data-action="close"','primary'))}
 if(t.dataset.queueFilter){S.queueFilter=t.dataset.queueFilter;render()}
 if(t.dataset.proposal){S.proposal=t.dataset.proposal;render()}
 if(t.dataset.proposalFilter){S.proposalFilter=t.dataset.proposalFilter;render()}
 if(t.dataset.history){S.page='history';S.historyId=t.dataset.history;render()}
 if(t.dataset.historyRequest){S.page='history';S.historyFilter='all';S.historyType='all';S.historyId='request-'+t.dataset.historyRequest;render()}
 if(t.dataset.historyFilter){S.historyFilter=t.dataset.historyFilter;render()}
 if(t.dataset.historyType){S.historyType=t.dataset.historyType;render()}
 if(t.dataset.revoke)modal('撤销授权','<p class="body-copy">后续读取和使用将被拒绝，已交付的文件副本会尝试回收。已经读取或上传的内容无法收回。</p><div id="form-error" class="form-error" hidden></div>',btn('取消','data-action="close"')+btn('确认撤销','data-confirm-revoke="'+t.dataset.revoke+'"','primary'));
 if(t.dataset.confirmRevoke){if(mutate(n=>{const h=n.history.find(h=>h.id===t.dataset.confirmRevoke);h.state='已撤销';h.ttl='手动撤销';h.events.push(['刚刚','撤销授权，后续使用被拒绝'])})){closeModal();render();toast('授权已撤销')}}
 if(t.dataset.coreNew)coreForm(t.dataset.coreNew);
 if(t.dataset.trashPreview){const i=D.trash.find(x=>x.id===t.dataset.trashPreview);modal(i.name,'<p class="body-copy">'+e(i.summary)+'</p><p>'+e(i.values?.body||'资料内容与原有结构一同保留。')+'</p>',btn('关闭','data-action="close"')+btn('恢复资料','data-restore-item="'+i.id+'"','primary'))}
 if(t.dataset.restoreItem){if(mutate(n=>{const i=n.trash.find(x=>x.id===t.dataset.restoreItem);delete i.deletedAt;n.items.push(i);n.trash=n.trash.filter(x=>x.id!==i.id)})){closeModal();render();toast('资料已恢复；旧授权未恢复')}}
 if(t.dataset.moveTo){if(mutate(n=>n.items.find(i=>i.id===S.selected).directory=t.dataset.moveTo)){closeModal();goItem(S.selected);toast('资料已移动')}}
 if(t.dataset.confirmDelete){if(mutate(n=>{const i=n.items.find(i=>i.id===S.selected);n.trash.push({...i,deletedAt:'2026-10-23'});n.items=n.items.filter(x=>x.id!==i.id);n.history.filter(h=>h.item===i.id&&h.state==='有效').forEach(h=>{h.state='已结束';h.ttl='资料已删除';h.events.push(['刚刚','资料删除，授权失效'])})})){closeModal();S.selected=filtered()[0]?.id;render();toast('资料已移入回收站')}}
 if(t.dataset.proposalDecision){const p=D.proposals.find(p=>p.id===S.proposal);if(p.status!=='待确认')return;if(t.dataset.proposalDecision==='accept'&&p.id==='update'&&byId(p.item).values.port!==p.before){modal('资料已发生变化','<p class="body-copy">提案创建后，SSH 端口已被更新。请重新核对当前内容，避免覆盖新的修改。</p>',btn('返回提案','data-action="close"'));return}if(mutate(n=>{const q=n.proposals.find(x=>x.id===p.id);q.status=t.dataset.proposalDecision==='accept'?'已入库':'已拒绝';if(q.status==='已入库'&&q.id==='import'){const tpl=clone(n.plugins.find(p=>p.id==='builtin.service').templates[0]);n.items.push({id:'proposal-record',name:q.name,summary:q.summary,kind:'service',templateId:'service',packageId:'builtin.service',templateVersion:'1.0.0',definition:tpl,directory:q.directory,tags:q.tags,updatedAt:'2026-10-23',values:{url:q.fields[0][1],purpose:q.fields[1][1],auth:''},relations:{hostedOn:['azure']}})}if(q.status==='已入库'&&q.id==='update'){n.revisions[q.item]??=[];n.revisions[q.item].push(clone(n.items.find(i=>i.id===q.item)));n.items.find(i=>i.id===q.item).values.port=q.after;q.status='已应用'}})){render();toast(t.dataset.proposalDecision==='accept'?'提案已应用到信息库':'已拒绝提案')}}
 switch(t.dataset.action){
 case 'edit-tags':showSimpleForm('资料标签','用逗号分隔，可复用或新增',(selected().tags||[]).join('，'),'record-tags',S.selected);document.getElementById('simple-value').required=false;break;
 case 'new-tag':showSimpleForm('新建标签','标签名称','','new-tag');break;
 case 'recycle':S.page='recycle';render();break;
 case 'move-record':modal('移动资料','<p class="muted">选择归放目录；模板和关联保持不变。</p><div id="form-error" class="form-error" hidden></div>'+D.dirs.filter(d=>d.id!=='all').map(d=>'<button class="directory" data-move-to="'+d.id+'">'+icon('folder')+e(d.name)+'</button>').join(''),btn('取消','data-action="close"'));break;
 case 'delete-record':modal('移入回收站','<p class="body-copy">“'+e(selected().name)+'”将保留 30 天，可以恢复。相关旧授权将失效。</p><div id="form-error" class="form-error" hidden></div>',btn('取消','data-action="close"')+btn('确认移入','data-confirm-delete="yes"','primary'));break;
 case 'revisions':{const rows=D.revisions[S.selected]||[];modal('内容版本','<div class="manage-row"><strong class="grow">当前版本</strong>'+pill('正在使用','green')+'</div>'+rows.slice().reverse().map((i,n)=>'<div class="revision-entry"><h3>修改前版本 '+(rows.length-n)+'</h3><p>'+e(i.name)+'</p><div class="facts">'+Object.entries(i.values||{}).filter(([,v])=>typeof v==='string').slice(0,4).map(([k,v])=>'<div class="fact"><label>'+e(i.definition?.fields.find(f=>f.key===k)?.label||k)+'</label><strong>'+e(v)+'</strong></div>').join('')+'</div></div>').join('')+(!rows.length?'<p class="empty-inline">还没有较早的内容版本。编辑保存后可在这里查看。</p>':''),btn('关闭','data-action="close"'));break}
 case 'edit-proposal':{const p=D.proposals.find(p=>p.id===S.proposal);showSimpleForm('编辑提案',p.id==='update'?'新的 SSH 端口':'资料名称',p.id==='update'?p.after:p.name,'proposal',p.id);break}
 }
});
document.addEventListener('input',ev=>{if(ev.target.id==='queue-search'){const pos=ev.target.selectionStart;S.queueQuery=ev.target.value;render();const input=document.getElementById('queue-search');input.focus();input.setSelectionRange(pos,pos)}});
document.addEventListener('submit',ev=>{
 if(ev.target.id==='simple-form'){ev.preventDefault();const v=document.getElementById('simple-value').value.trim(),kind=ev.target.dataset.kind,id=ev.target.dataset.identity;let err='';if(kind==='directory'&&D.dirs.some(d=>d.name===v&&d.id!==id))err='已有同名目录。';if(['tag','new-tag'].includes(kind)&&D.tags.includes(v)&&v!==id)err='已有同名标签。';if(err){const el=document.getElementById('form-error');el.hidden=false;el.textContent=err;return}if(mutate(n=>{if(kind==='directory')n.dirs.find(d=>d.id===id).name=v;if(kind==='record-tags'){const tags=[...new Set(v.split(/[,，]/).map(x=>x.trim()).filter(Boolean))];n.items.find(i=>i.id===id).tags=tags;n.tags=[...new Set([...n.tags,...tags])]}if(kind==='new-tag')n.tags.push(v);if(kind==='tag'){n.tags=n.tags.map(x=>x===id?v:x);n.items.forEach(i=>i.tags=(i.tags||[]).map(x=>x===id?v:x));if(S.tag===id)S.tag=v}if(kind==='proposal'){const p=n.proposals.find(x=>x.id===id);if(id==='update')p.after=v;else p.name=v}})){closeModal();render();toast('已保存')}}
 if(ev.target.id==='core-form'){ev.preventDefault();const kind=ev.target.dataset.kind,old=editId?byId(editId):null,file=document.getElementById('core-file')?.files[0];const item={...old,id:old?.id||'core-'+crypto.randomUUID(),name:document.getElementById('core-name').value.trim(),summary:document.getElementById('core-desc').value.trim(),kind,directory:old?.directory||(S.dir==='all'?'unfiled':S.dir),tags:old?.tags||[],relations:old?.relations||{},values:{body:document.getElementById('core-body')?.value||''},filename:file?.name||old?.filename,format:kind==='credential'?(file?'凭据文件':'Token 字符串'):file?.type||old?.format,binding:document.getElementById('binding-name')?.value,updatedAt:'2026-10-23'};if(mutate(n=>{const at=n.items.findIndex(i=>i.id===item.id);if(at>=0){n.revisions[item.id]??=[];n.revisions[item.id].push(clone(n.items[at]));n.items[at]=item}else n.items.push(item)})){closeModal();goItem(item.id);toast('资料已保存')}}
});

document.querySelectorAll('[data-icon]').forEach(el=>el.innerHTML=icon(el.dataset.icon));
window.ROUND9=window.ROUND8={get data(){return D},state:S,validatePackage};
if(S.page==='plugins'){S.page='settings';S.setting='plugins'}
render();
if(params.get('state')==='install'){pending=clone(MODEL.domainPackage);packageErrors=validatePackage(pending);installDialog()}
if(params.get('state')==='new')chooser();
})();
