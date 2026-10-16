const originalCredentialViews=window.credentialViews;
window.credentialViews=()=>{
 const state=originalCredentialViews(), initialize=state.credentialInit;
 return Object.defineProperties(state,Object.getOwnPropertyDescriptors({
  tip:'', requestDetailOpen:false,
  get runtime(){return this.useRequest},
  get deliveryName(){return {env_value:'秘密值 → 环境变量',file_arg:'临时文件路径 → 命令参数',file_env:'临时文件路径 → 环境变量'}[this.runtime.delivery]},
  get destinationLabel(){return this.runtime.delivery==='file_arg'?'参数位置':'环境变量名'},
  get destination(){return this.runtime.delivery==='file_arg'?'ssh 的 -i 参数':this.runtime.binding},
  get receivedValue(){return this.runtime.delivery==='env_value'?'真实 Token（不展示原文）':'CLI 生成的临时文件路径'},
  get requestPayload(){return JSON.stringify({command:'request-use',purpose:this.runtime.description,credentials:[{alias:this.runtime.alias,credentialId:this.runtime.credential,version:this.useCredential.version}],launch:{executable:this.runtime.executable,argv:this.runtime.argv,cwd:'C:\\Work\\northstar',env:this.runtime.delivery==='env_value'?{GH_TOKEN:{secret:this.runtime.alias}}:this.runtime.delivery==='file_env'?{AWS_SHARED_CREDENTIALS_FILE:{file:this.runtime.alias}}:{}},readFields:this.runtime.fields?this.items.find(i=>i.id==='test').fields.map(f=>({itemId:'test',fieldId:f.id})):[]},null,2)},
  toggleTip(id){this.tip=this.tip===id?'':id},
  showRequest(){this.openCredentialDialog('request')},
  credentialInit(){
   this.useRequests['REQ-026']= {...this.useRequests['REQ-026'],delivery:'file_arg',alias:'ssh_key',binding:'{{file:ssh_key}}',command:'ssh -i {{file:ssh_key}} -p 2222 developer@test.beichen.example',executable:'C:\\Windows\\System32\\OpenSSH\\ssh.exe',argv:['-i',{file:'ssh_key'},'-p','2222','developer@test.beichen.example']};
   this.useRequests['REQ-025']= {...this.useRequests['REQ-025'],delivery:'env_value',alias:'github_token',executable:'C:\\Program Files\\GitHub CLI\\gh.exe',argv:['repo','view','northstar/agent-skills']};
   initialize.call(this);
   this.credentials.push({id:'aws-test',name:'测试账号访问配置',form:'file',purpose:'AWS 凭据文件',fileName:'credentials',size:'216 B',variable:'aws_config',version:1,status:'可用',expires:'未设置',lastUsed:'尚未使用',note:'用于核对测试账号身份，文件内采用 default 配置段。'});
   this.useRequests['REQ-027']={credential:'aws-test',item:'deploy',task:'核对测试云账号身份',target:'AWS · 测试账号',program:'aws',delivery:'file_env',alias:'aws_config',binding:'AWS_SHARED_CREDENTIALS_FILE',command:'aws sts get-caller-identity --region us-east-1',executable:'C:\\Program Files\\Amazon\\AWSCLIV2\\aws.exe',argv:['sts','get-caller-identity','--region','us-east-1'],description:'用测试账号配置核对当前身份，确认后续任务使用的账号。',fields:false};
   this.requests.splice(2,0,{id:'REQ-027',title:'核对测试云账号身份',agent:'Codex',kind:'使用凭据',itemIds:['deploy'],time:'14:34',state:'待处理',purpose:'核对当前 AWS 账号身份。',scope:'1 项凭据'});
   for(const g of this.grants)if(g.kind==='凭据使用'&&!g.snapshot)g.snapshot={...this.useRequests['REQ-026'],credentialName:'测试服务器部署密钥',version:2,form:'file',minutes:'15',fields:[]};
   const q=new URLSearchParams(location.search);
   if(q.get('state')==='file-env'){this.page='approvals';this.requestId='REQ-027'}
   if(q.get('state')==='tip'){this.page='approvals';this.tip='injection'}
   if(q.get('state')==='request'){this.page='approvals';this.$nextTick(()=>this.showRequest())}
   this.$watch('requestId',()=>this.tip='');
  }
 }));
};
