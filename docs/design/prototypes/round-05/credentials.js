const previousMergeViews=window.mergeViews;
window.mergeViews=base=>Object.defineProperties(previousMergeViews(base),Object.getOwnPropertyDescriptors(credentialViews()));
window.credentialViews=()=>({
 credentials:[
 {id:'ssh-deploy',name:'测试服务器部署密钥',form:'file',purpose:'SSH 私钥',fileName:'deploy_ed25519',size:'464 B',variable:'ssh_key',version:2,status:'可用',expires:'未设置',lastUsed:'今天 13:22',note:'用于测试环境的部署与连接排查。'},
 {id:'github-skills',name:'GitHub · 技能仓库 Token',form:'string',purpose:'API Token',fileName:'',size:'',variable:'GH_TOKEN',version:1,status:'可用',expires:'2026 / 12 / 31',lastUsed:'今天 14:05',note:'用于技能仓库的日常维护。'},
 {id:'docs-token',name:'文档服务访问 Token',form:'string',purpose:'API Token',fileName:'',size:'',variable:'DOCS_TOKEN',version:3,status:'可用',expires:'2026 / 11 / 30',lastUsed:'昨天',note:'用于调用文档服务接口。'},
 {id:'old-token',name:'归档服务旧 Token',form:'string',purpose:'API Token',fileName:'',size:'',variable:'ARCHIVE_TOKEN',version:1,status:'已过期',expires:'2026 / 10 / 01',lastUsed:'10 月 01 日',note:'旧服务凭据，保留供更换与追溯。'}],
 credentialId:'ssh-deploy',credentialFilter:'all',credentialSearch:'',credentialTab:'details',
 links:{test:['ssh-deploy'],docs:['docs-token'],deploy:['github-skills']},
 get credential(){return this.credentials.find(c=>c.id===this.credentialId)||this.credentials[0]},
 get credentialResults(){return this.credentials.filter(c=>(this.credentialFilter==='all'||c.form===this.credentialFilter)&&(c.name+c.purpose).toLowerCase().includes(this.credentialSearch.toLowerCase()))},
 get linkedItems(){return this.items.filter(i=>(this.links[i.id]||[]).includes(this.credentialId))},
 get credentialRecords(){return this.grants.filter(g=>g.kind==='凭据使用'&&(g.snapshot?.credential||'ssh-deploy')===this.credentialId)},
 showCredentialRecords(){if(!this.credentialRecords.length)return;this.historyId=this.credentialRecords[0].id;this.historySearch='';this.historyFilter='all';this.historyPage=0;this.page='history'},
 get itemCredentials(){return (this.links[this.itemId]||[]).map(id=>this.credentials.find(c=>c.id===id)).filter(Boolean)},
 credentialDialog:'',linkedDraft:[],credentialForm:'string',credentialName:'',credentialFileName:'',credentialInput:'',credentialPurpose:'API Token',credentialVariable:'SERVICE_TOKEN',credentialError:'',
 allowCredential:true,useMinutes:'15',allowedFields:['test-address','test-port','test-user'],useDecision:{},
 useRequests:{
 'REQ-026':{credential:'ssh-deploy',item:'test',task:'排查测试环境连接',target:'test.beichen.example · developer · 2222',program:'ssh',command:'ssh -i {{file:ssh_key}} -p 2222 developer@test.beichen.example',description:'建立 SSH 连接，检查测试环境连通性。',binding:'{{file:ssh_key}}',fields:true},
 'REQ-025':{credential:'github-skills',item:'deploy',task:'检查技能仓库状态',target:'GitHub · northstar/agent-skills',program:'gh',command:'gh repo view northstar/agent-skills',description:'核对仓库信息，为同步技能库做准备。',binding:'GH_TOKEN',fields:false}
 },
 get useRequest(){return this.useRequests[this.requestId]||this.useRequests['REQ-026']},
 get useCredential(){return this.credentials.find(c=>c.id===this.useRequest.credential)},
 get useApproved(){return this.useDecision[this.requestId]||null},
 get useGrant(){return this.grants.find(g=>g.id==='USE-'+this.requestId)},
 get canApproveUse(){return this.allowCredential&&this.useCredential.status==='可用'&&this.currentRequest.state==='待处理'},
 get useCountLabel(){return this.useRequest.fields?'1 项凭据 + '+this.allowedFields.length+' 个字段':'1 项凭据'},
 openCredential(id){this.credentialId=id;this.page='credentials';this.credentialTab='details';this.credentialFilter='all';this.credentialSearch=''},
 openLinkedItem(id){this.itemId=id;this.folder='all';this.itemSearch='';this.page='library'},
 openCredentialDialog(kind){this.lastCredentialFocus=document.activeElement;this.credentialDialog=kind;this.credentialError='';this.$nextTick(()=>this.$refs.credentialClose?.focus())},
 closeCredentialDialog(){this.credentialDialog='';this.lastCredentialFocus?.focus()},
 editLinks(){this.linkedDraft=[...(this.links[this.itemId]||[])];this.openCredentialDialog('link')},
 saveLinks(){this.links[this.itemId]=this.linkedDraft.slice();this.closeCredentialDialog()},
 newCredential(){this.credentialName='';this.credentialInput='';this.credentialFileName='';this.credentialForm='string';this.credentialPurpose='API Token';this.credentialVariable='SERVICE_TOKEN';this.openCredentialDialog('new')},
 get canSaveCredential(){return this.credentialName.trim()&&(this.credentialForm==='string'?this.credentialInput.trim():this.credentialFileName)&&(this.credentialForm==='file'?/^[A-Za-z_][A-Za-z0-9_]{0,63}$/:/^[A-Z_][A-Z0-9_]*$/).test(this.credentialVariable)},
 saveCredential(){if(!this.canSaveCredential)return;const id='local-'+Date.now();this.credentials.push({id,name:this.credentialName.trim(),form:this.credentialForm,purpose:this.credentialForm==='file'?'凭据文件':this.credentialPurpose,fileName:this.credentialFileName,size:'已选择',variable:this.credentialVariable,version:1,status:'可用',expires:'未设置',lastUsed:'尚未使用',note:'手动添加的凭据。'});this.credentialInput='';this.closeCredentialDialog();this.openCredential(id)},
 approveUse(){if(!this.canApproveUse)return;const snapshot={...this.useRequest,credentialName:this.useCredential.name,version:this.useCredential.version,form:this.useCredential.form,minutes:this.useMinutes,fields:this.useRequest.fields?this.allowedFields.slice():[]};this.useDecision[this.requestId]=snapshot;this.currentRequest.state='已批准';this.grants.unshift({id:'USE-'+this.requestId,title:this.useRequest.task,agent:'Codex',state:'有效',time:'14:40',expires:this.useMinutes==='15'?'14:55':'15:10',count:1,reads:0,kind:'凭据使用',usage:'pending',snapshot});this.closeCredentialDialog()},
 rejectUse(){this.currentRequest.state='已拒绝';this.closeCredentialDialog()},
 viewUseHistory(){this.historyId='USE-'+this.requestId;this.historyFilter='all';this.historySearch='';this.historyPage=0;this.page='history'},
 get historyCredential(){return this.grant.snapshot||{credentialName:'测试服务器部署密钥',version:2,form:'file',binding:'{{file:ssh_key}}',program:'ssh',target:'test.beichen.example · developer · 2222',command:'ssh -i {{file:ssh_key}} -p 2222 developer@test.beichen.example',minutes:'15',fields:[]}},
 stopCredentialUse(){this.grant.state='已撤销';this.grant.expires='14:45';this.closeCredentialDialog()},
 credentialInit(){
  const q=new URLSearchParams(location.search);
  this.items.find(i=>i.id==='docs').fields=this.items.find(i=>i.id==='docs').fields.filter(f=>!f.secret);
  for(const r of this.requests)if(r.kind==='读取信息')r.scope=r.itemIds.reduce((n,id)=>n+this.items.find(i=>i.id===id).fields.length,0)+' 个字段';
  this.requests.unshift({id:'REQ-026',title:'排查测试环境连接',agent:'Codex',kind:'使用凭据',itemIds:['test'],time:'14:38',state:'待处理',purpose:'使用部署私钥连接测试服务器，排查连接失败原因。',scope:'1 项凭据'},{id:'REQ-025',title:'检查技能仓库状态',agent:'Codex',kind:'使用凭据',itemIds:['deploy'],time:'14:36',state:'待处理',purpose:'使用 GitHub Token 核对技能仓库的信息。',scope:'1 项凭据'});
  this.grants.unshift({id:'USE-023',title:'测试环境连接检查',agent:'Codex',state:'已结束',time:'13:20',expires:'13:22',count:1,reads:1,kind:'凭据使用',usage:'cleaned'},{id:'USE-021',title:'测试环境部署',agent:'Codex',state:'已结束',time:'昨天',expires:'昨天 18:40',count:1,reads:1,kind:'凭据使用',usage:'cleanup-failed'});
  const order=t=>/^\d{2}:/.test(t)?'3'+t:t.startsWith('昨天')?'2'+t:'1'+t;
  this.grants.sort((a,b)=>order(b.time).localeCompare(order(a.time)));
  if(q.get('page')==='credentials'){this.page='credentials';if(q.get('state')==='token')this.credentialId='github-skills';if(q.get('state')==='expired')this.credentialId='old-token'}
  if(q.get('state')==='server'){this.page='library';this.itemId='test';this.folder='工作/测试环境'}
  if(q.get('state')==='use-file'){this.page='approvals';this.requestId='REQ-026'}
  if(q.get('state')==='use-token'){this.page='approvals';this.requestId='REQ-025'}
  if(q.get('state')==='usage'){this.page='history';this.historyId='USE-023'}
  if(q.get('state')==='cleanup'){this.page='history';this.historyId='USE-021'}
  this.$watch('requestId',()=>{this.allowCredential=true;this.useMinutes='15';this.allowedFields=['test-address','test-port','test-user']});
  for(const key of ['credentialFilter','credentialSearch'])this.$watch(key,()=>{if(this.credentialResults.length&&!this.credentialResults.some(c=>c.id===this.credentialId))this.credentialId=this.credentialResults[0].id});
 }
});
