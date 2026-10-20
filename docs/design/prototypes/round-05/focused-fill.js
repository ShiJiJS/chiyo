// Design-only focused-fill states. Never reads a password or calls native input.
const focusedFillMerge=window.mergeViews;
window.mergeViews=base=>{
 const app=focusedFillMerge(base),init=app.init,approve=app.approveUse;
 const canApprove=Object.getOwnPropertyDescriptor(app,'canApproveUse').get;
 Object.defineProperties(app,Object.getOwnPropertyDescriptors({
  fillDialog:'',fillError:'',selectedFillOperation:'',fillPage:0,
  get isFocusedFill(){return this.useRequests[this.requestId]?.delivery==='focused_fill'},
  get canApproveFill(){return this.isFocusedFill&&this.currentRequest.state==='待处理'&&this.allowCredential&&this.useCredential.form==='string'&&this.useCredential.status==='可用'&&['15','30'].includes(this.useMinutes)},
  get canApproveUse(){return this.isFocusedFill?this.canApproveFill:canApprove.call(this)},
  get fillOperations(){return this.grant?.focusedFill?this.grant.operations:[]},
  get fillPages(){return Math.max(1,Math.ceil(this.fillOperations.length/8))},
  get fillCurrentPage(){return Math.min(this.fillPage,this.fillPages-1)},
  get fillVisibleOperations(){return this.fillOperations.slice().reverse().slice(this.fillCurrentPage*8,this.fillCurrentPage*8+8)},
  changeFillPage(delta){this.fillPage=Math.max(0,Math.min(this.fillPages-1,this.fillCurrentPage+delta));this.selectedFillOperation=this.fillVisibleOperations[0]?.id||''},
  get fillOperation(){return this.fillOperations.find(op=>op.id===this.selectedFillOperation)||this.fillOperations.at(-1)},
  fillStateLabel(state){return {checking:'正在核验',sent:'输入已发送',refused:'未输入',partial:'部分发送',unknown:'结果未知'}[state]||state},
  get fillNextStep(){return {checking:'等待本次操作完成，先查询原操作。',sent:'按键已提交给 Windows；未读取密码框确认，也未提交登录。',refused:'本次未发送按键。修正原因后，可明确发起新操作。',partial:'可能已留下部分内容。停止自动填充，由用户检查并清空后决定是否重新操作。',unknown:'无法确认是否已输入。只查询原操作；不要自动更换操作 ID 重填。'}[this.fillOperation?.state]||'批准本身不会输入任何内容。'},
  openFillDialog(kind='approve'){this.lastFillFocus=document.activeElement;this.fillError='';this.fillDialog=kind;this.$nextTick(()=>this.$refs.fillClose?.focus())},
  closeFillDialog(){if(!this.fillDialog)return;this.fillDialog='';const focus=this.lastFillFocus;this.lastFillFocus=null;focus?.focus()},
  approveUse(){if(this.isFocusedFill){this.approveFocusedFill();return}approve.call(this)},
  approveFocusedFill(){
   if(!this.canApproveFill)return;
   if(this.injectFailure){this.fillError='审批未保存，未创建授权。当前选择已保留。';return}
   const snapshot={...this.useRequest,application:{...this.useRequest.application},credentialName:this.useCredential.name,version:this.useCredential.version,form:'string',minutes:this.useMinutes,fields:[]};
   this.useDecision[this.requestId]={use:true,fields:[],snapshot};this.currentRequest.state='已批准';
   this.grants.unshift({id:'USE-'+this.requestId,title:this.useRequest.task,agent:'Codex',state:'有效',time:'今天 14:40',expires:this.useMinutes==='15'?'今天 14:55':'今天 15:10',count:1,reads:0,kind:'凭据使用',focusedFill:true,reusable:true,usage:'pending',snapshot,operations:[]});
   this.closeFillDialog();
  },
  rejectFocusedFill(){if(this.currentRequest.state==='待处理')this.currentRequest.state='已拒绝';this.closeFillDialog()},
  recordFillOperation(id,state='sent',reason=''){
   const grant=this.grant;if(!grant?.focusedFill)return 'wrong_usage';
   const old=grant.operations.find(op=>op.id===id);if(old)return old;
   if(grant.state!=='有效')return 'grant_revoked';
   if(grant.operations.some(op=>op.state==='checking'||(['partial','unknown'].includes(op.state)&&!op.attentionAcknowledgedAt)))return 'needs_attention';
   const op={id,state,reason,time:'今天 14:45',application:grant.snapshot.application.name,targetType:'password'};
   grant.operations.push(op);grant.reads=grant.operations.length;this.selectedFillOperation=id;return op;
  },
  revokeFocusedFill(){if(this.grant?.focusedFill)this.grant.state='已撤销'},
  acknowledgeFocusedFill(){
   const op=this.fillOperation;if(!op||!['partial','unknown'].includes(op.state)||op.attentionAcknowledgedAt)return;
   if(this.injectFailure){this.fillError='确认未保存，仍需人工检查。原输入结果保持不变。';return}
   op.attentionAcknowledgedAt='今天 14:48';this.closeFillDialog();
  },
  initializeFocusedFill(){
   this.credentials.push({id:'portal-password',name:'北辰工作台登录密码',form:'string',purpose:'登录密码',fileName:'',variable:'',version:1,status:'可用',expires:'未设置',lastUsed:'尚未使用',note:'工作台网页登录使用。'});
   this.useRequests['REQ-028']={credential:'portal-password',item:'docs',task:'登录北辰工作台',description:'登录工作台，继续填写项目发布资料。',delivery:'focused_fill',fields:false,target:'https://portal.beichen.example/login',application:{name:'工作浏览器',executable:'C:\\Apps\\WorkBrowser\\WorkBrowser.exe',sha256:'8b'+('31'.repeat(31))}};
   this.requests.unshift({id:'REQ-028',title:'登录北辰工作台',agent:'Codex',kind:'使用凭据',itemIds:['docs'],time:'14:39',state:'待处理',purpose:'登录工作台继续填写项目发布资料。',scope:'1 项凭据 · 本机焦点填充'});
   const state=new URLSearchParams(location.search).get('state')||'';
   if(!state.startsWith('fill-'))return;
   this.page='approvals';this.requestId='REQ-028';this.flow='';
   if(state==='fill-long-target'){this.useCredential.name='北辰工作台跨区域项目发布与协作系统登录密码';this.useRequest.application.name='WorkBrowserEnterpriseForNorthstarProjectOperations';this.useRequest.application.executable='C:\\工具与应用\\项目协作浏览器\\'+('Northstar'.repeat(9))+'\\WorkBrowser.exe';this.useRequest.target='https://portal.beichen.example/'+('project-release-'.repeat(9))+'login'}
   if(state==='fill-tip')this.tip='fill-target';
   if(state==='fill-incompatible')this.useRequests['REQ-028'].credential='ssh-deploy';
   if(state==='fill-save-failed'){this.injectFailure=true;this.openFillDialog();this.approveFocusedFill()}
   if(state==='fill-confirm')this.openFillDialog();
   if(state==='fill-rejected'){this.rejectFocusedFill();return}
   if(['fill-result','fill-history','fill-sent','fill-refused','fill-partial','fill-unknown','fill-checking','fill-revoked'].includes(state)){
    this.approveFocusedFill();
    if(state==='fill-result')return;
    this.viewUseHistory();
    if(state==='fill-history'||state==='fill-revoked'){this.recordFillOperation('FILL-01');this.recordFillOperation('FILL-02','refused','目标已变为普通文本框，未发送按键。')}
    else this.recordFillOperation('FILL-01',state.slice(5),{refused:'桌面已锁定，未发送按键。',partial:'发送期间焦点变化，后续输入已停止。',unknown:'输入放行后通信中断，无法确认已发送范围。',checking:'正在核对本次前台应用和密码控件。'}[state.slice(5)]||'');
    if(state==='fill-revoked')this.revokeFocusedFill();
   }
  }
 }));
 app.init=function(){init.call(this);this.initializeFocusedFill();this.$nextTick(()=>{for(const key of ['page','requestId'])this.$watch(key,()=>this.closeFillDialog())})};return app;
};
