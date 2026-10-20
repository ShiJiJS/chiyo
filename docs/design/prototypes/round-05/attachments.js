// Design model only: metadata and in-memory transitions; no file bytes or service.
const attachmentMerge = window.mergeViews;
window.mergeViews = base => {
 const app = attachmentMerge(base);
 const previous = Object.fromEntries(['init','beginItem','addEditorField','saveItem','decideRead','closeFlow'].map(k=>[k,app[k]]));
 const previousScope=Object.getOwnPropertyDescriptor(app,'grantScope').get;
 const copy = value => JSON.parse(JSON.stringify(value));
 Object.defineProperties(app,Object.getOwnPropertyDescriptors({
  attachmentSequence:0, attachmentSaving:false, attachmentEvents:[], attachmentNotice:'',
  attachmentTab:'scope', attachmentReturn:'', attachmentTemplate:false,
  attachmentId(prefix='field'){return prefix+'-attachment-'+(++this.attachmentSequence)},
  formatBytes(n){return n<1024?n+' B':n<1048576?(n/1024).toFixed(1)+' KiB':(n/1048576).toFixed(1)+' MiB'},
  fileSummary(f){return f.kind==='file'?(f.file?f.file.name+' · '+this.formatBytes(f.file.size)+' · 版本 '+f.file.version:'尚未选择文件'):f.value},
  get hasAttachment(){return this.currentItem.fields.some(f=>f.kind==='file')},
  get currentItems(){return (this.currentRequest?.itemIds||[]).map(id=>this.items.find(i=>i.id===id)).filter(Boolean)},
  get filteredRequests(){return this.requests.filter(r=>(this.requestFilter==='all'||(this.requestFilter==='pending'?r.state==='待处理':r.state!=='待处理'))&&[r.title,r.agent,...r.itemIds.map(id=>this.items.find(i=>i.id===id)?.name||'已删除的信息')].join(' ').toLowerCase().includes(this.requestSearch.toLowerCase()))},
  get attachmentGrant(){return this.grants.find(g=>g.attachmentScope)},
  get grantScope(){return this.grant?.attachmentScope?this.grant.attachmentScope.map(i=>[i.name,i.fields.map(f=>f.name+(f.kind==='file'?'（文件 · 版本 '+f.file.version+'）':'')).join('、'),i.fields.some(f=>f.kind==='file')]):previousScope.call(this)},
  get fileCapacity(){return this.items.flatMap(i=>i.fields).filter(f=>f.kind==='file'&&f.file).reduce((n,f)=>n+f.file.size,0)},
  beginItem(fresh=false){previous.beginItem.call(this,fresh);this.editor.fields.forEach(f=>{f.kind ||= 'structured';f.originalId=f.id;f.originalKind=f.kind;f.originalName=f.name});this.attachmentNotice=''},
  addEditorField(){previous.addEditorField.call(this);const f=this.editor.fields.at(-1);f.id=this.attachmentId();f.kind='structured'},
  changeFieldKind(f,kind){if(f.kind===kind)return;f.kind=kind;delete f.file;if(kind==='file')delete f.value;else f.value='';f.fileError='';this.attachmentNotice='更改字段类型后将建立新字段，原授权不会转移。'},
  pickAttachment(f,file){
   f.fileError='';if(!file)return;
   if(file.size>10*1048576){f.fileError='文件超过 10 MiB，请选择更小的文件。';return}
   f.file={name:file.name,size:file.size,type:file.type||'application/octet-stream',version:(f.file?.version||0)+1,ref:this.attachmentId('staged')};
  },
  async saveItem(){
   if(this.attachmentSaving)return;
   const invalid=this.editor.fields.find(f=>f.kind==='file'&&(!f.file||f.fileError));
   if(invalid){invalid.fileError ||= '请选择要保存的文件。';this.flowError='有文件字段尚未准备好，请检查后保存。';return}
   if(this.editor.fields.some(f=>!['structured','textNote','file'].includes(f.kind||'structured'))){this.flowError='包含不支持的字段类型，未修改原信息。';return}
   this.attachmentSaving=true;await Promise.resolve();
   try {
    // Work on a copy: failed commits must not change draft identities or library.
    const draft=this.editor;this.editor=copy(draft);
    this.editor.fields.forEach(f=>{if(f.originalId&&(f.kind!==f.originalKind||f.name!==f.originalName))f.id=this.attachmentId();for(const k of ['fileError','originalId','originalKind','originalName'])delete f[k]});
    previous.saveItem.call(this);
    if(this.flow)this.editor=draft;
   } finally {this.attachmentSaving=false}
  },
  closeFlow(){previous.closeFlow.call(this);this.attachmentNotice=''},
  useFileTemplate(){
   this.beginItem(true);this.editor.name='求职资料';this.editor.path='个人 / 求职';this.editor.publicDescription='求职时需要的基本信息和简历';
   this.editor.fields=[{name:'姓名',description:'用于填写个人资料',kind:'structured',value:''},{name:'求职说明',description:'个人求职偏好',kind:'textNote',value:''},{name:'简历',description:'可领取的简历原文件',kind:'file'}].map(f=>({...f,id:this.attachmentId()}));
   this.attachmentTemplate=true;
  },
  replaceAttachment(id){this.beginItem(false);this.$nextTick(()=>document.querySelector?.('[data-file-id="'+id+'"]')?.focus())},
  showAttachmentPublic(){this.openFlow('attachment-public')},
  openAttachmentHistory(){this.openFlow('attachment-history')},
  async decideRead(approve){
   const isFile=this.currentRequest.id==='REQ-ATTACHMENT';
   const scope=isFile?this.approvedItems.map(i=>({id:i.id,name:i.name,fields:copy(i.fields.filter(f=>this.selection.includes(f.id)))})):null;
   previous.decideRead.call(this,approve);
   if(isFile&&approve&&!this.injectFailure&&this.currentRequest.state==='已批准'){
    const g=this.grants[0];g.attachmentScope=scope;g.count=scope.reduce((n,i)=>n+i.fields.length,0);
    const end=15*60+Number(this.duration);g.time='今天 15:00';g.expires='今天 '+String(Math.floor(end/60)).padStart(2,'0')+':'+String(end%60).padStart(2,'0');
    this.attachmentNotice='已批准所选字段，未选择的内容不会提供。';this.openFlow('attachment-history');
   }
  },
  recordFileDelivery(){
   const g=this.attachmentGrant;if(!g||g.state!=='有效')return;
   const approved=g.attachmentScope.flatMap(i=>i.fields).find(f=>f.kind==='file');
   const field=approved&&this.items.flatMap(i=>i.fields).find(f=>f.id===approved.id&&f.kind==='file');if(!field)return;
   this.attachmentEvents.unshift({id:this.attachmentId('delivery'),field:field.name,version:field.file.version,time:'今天 15:02',state:'已交付'});g.reads++;
  },
  revokeAttachment(){if(this.attachmentGrant)this.attachmentGrant.state='已撤销';this.attachmentEvents.forEach(e=>e.state='待回收副本');this.attachmentNotice='停止新领取；已被读取或复制的内容无法收回。'},
  saveAttachmentCopy(f){this.attachmentNotice='已选择另存「'+f.file.name+'」。';this.openFlow('attachment-export')},
  get attachmentPublicFields(){return this.currentItem.fields.map(f=>({name:f.name,description:f.description,kind:f.kind||'structured'}))},
  attachmentInit(){
   const q=new URLSearchParams(location.search),state=q.get('state')||'';
   if(!state.startsWith('attachment-'))return;
   this.theme=q.get('theme')||this.theme;
   const sample={id:'career',name:'求职资料',path:'个人 / 求职',category:'求职',tag:'个人',description:'求职时需要的基本信息和简历',fields:[
    {id:'career-name',name:'姓名',description:'填写个人资料',value:'林予安',kind:'structured'},
    {id:'career-note',name:'求职说明',description:'个人偏好及补充说明',value:'优先考虑远程工作机会。',kind:'textNote'},
    {id:'career-resume',name:'简历',description:'可领取的简历原文件',kind:'file',file:{ref:'attachment-sample-v1',name:'林予安的个人简历与项目经历.pdf',size:248320,type:'application/pdf',version:1}}
   ]};
   this.items.push(sample);this.itemId=sample.id;this.page='library';this.folder='all';this.itemSearch='';this.expanded.push('个人');
   this.tree.find(n=>n.path==='个人').hasChildren=true;this.tree.push({name:'求职',path:'个人/求职',depth:1});
   this.requests.unshift({id:'REQ-ATTACHMENT',title:'填写求职网站个人资料',agent:'Codex',kind:'读取信息',state:'待处理',time:'14:58',itemIds:['career'],purpose:'阅读简历，填写个人资料并上传简历文件。',description:'阅读简历，填写个人资料并上传简历文件。'});
   this.requestDrafts['REQ-ATTACHMENT']={selection:['career-name','career-resume'],duration:'480'};
   this.requestId='REQ-ATTACHMENT';this.selection=['career-name','career-resume'];this.duration='480';
   this.$nextTick(()=>{this.selection=['career-name','career-resume'];this.duration='480'});
   const route=state.slice(11);
   if(['editor','file-field','empty-file','failure','long-name','only-file','too-large','converted'].includes(route)){
    this.beginItem(route==='empty-file'||route==='only-file');
    if(route==='empty-file'||route==='only-file'){this.editor.name='个人简历';this.editor.fields=[{id:this.attachmentId(),name:'简历',kind:'file',description:'求职用简历原文件'}]}
    if(route==='long-name')this.editor.fields[2].file.name='林予安_个人简历_完整项目经历与作品链接_应聘研发岗位_2026年10月更新版.pdf';
    if(['file-field','long-name','too-large'].includes(route))this.$nextTick(()=>document.querySelector?.('[data-file-id="career-resume"]')?.focus());
    if(route==='too-large')this.pickAttachment(this.editor.fields[2],{name:'large.pdf',size:11*1048576});
    if(route==='converted'){this.changeFieldKind(this.editor.fields[2],'textNote');this.editor.fields[2].value='文件字段改为说明，需要重新授权。'}
    if(route==='failure'){this.editor.fields[0].value='林予安（已修改）';this.injectFailure=true;this.saveItem()}
   }
   if(route==='approval')this.page='approvals';
   if(route==='public')this.showAttachmentPublic();
   if(route==='template')this.openFlow('attachment-template');
   if(route==='history'){this.decideRead(true);this.recordFileDelivery()}
   if(route==='trash')this.deleteItem();
   if(route==='revision'){this.revisions=[copy(sample)];sample.fields[2].file.version=2;this.openFlow('revision')}
   if(route==='restore'){this.page='settings';this.restoreEmpty=true;this.backupFileSelected=this.backupRecoverySelected=true;this.restorePreview=true;this.openFlow('backup')}
   if(route==='proposal'){this.openFlow('attachment-proposal')}
  }
 }));
 app.init=function(){previous.init.call(this);this.attachmentInit()};
 return app;
};
