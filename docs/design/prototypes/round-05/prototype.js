document.addEventListener('alpine:init',()=>{
 const field=(id,name,value,description='',secret=false)=>({id,name,value,description,secret});
 const items=[
 {id:'docs',name:'文档服务',path:'工作 / 北辰项目 / 服务',category:'服务',tag:'自托管',description:'北辰项目的文档访问入口与部署配置',publicDescription:'提供项目文档的访问入口、部署目录及访问认证信息。',fields:[field('url','访问地址','https://docs.beichen.example','文档站的公开访问入口'),field('dir','部署目录','/srv/beichen/docs','服务器上的文档存放位置'),field('token','访问令牌','••••••••••••••••','用于服务访问认证',true)]},
 {id:'project',name:'项目约定',path:'工作 / 北辰项目 / 项目资料',category:'项目资料',tag:'开发',description:'项目代号、日常协作与联系信息',fields:[field('code','项目代号','BEICHEN','用于配置与部署时识别项目'),field('mail','联系人邮箱','owner@beichen.example','项目维护联系地址')]},
 {id:'api',name:'接口服务',path:'工作 / 北辰项目 / 服务',category:'服务',tag:'开发',description:'业务接口入口与开发环境说明',fields:[field('api-url','访问地址','https://api.beichen.example','项目业务接口'),field('api-version','接口版本','v2','当前使用的接口版本')]},
 {id:'backup',name:'备份服务',path:'工作 / 北辰项目 / 服务',category:'服务',tag:'自托管',description:'项目备份目录与执行时间',fields:[field('backup-dir','备份目录','/backup/beichen','备份文件存放位置'),field('backup-time','执行时间','每天 02:00','计划执行时间')]},
 {id:'deploy',name:'部署说明',path:'工作 / 北辰项目 / 项目资料',category:'项目资料',tag:'开发',description:'发布流程与环境切换约定',fields:[field('branch','发布分支','release','用于发布的分支'),field('deploy-note','发布约定','发布前先检查测试环境','项目部署约定')]},
 {id:'monitor',name:'监测服务',path:'工作 / 北辰项目 / 服务',category:'服务',tag:'自托管',description:'服务运行状态与通知入口',fields:[field('monitor-url','访问地址','https://status.beichen.example','状态面板入口'),field('monitor-owner','维护人','项目维护组','服务的日常维护人')]},
 {id:'test',name:'测试服务器',path:'工作 / 测试环境',category:'服务',tag:'开发',description:'用于联调与验收的测试环境',fields:[field('test-address','服务器地址','test.beichen.example','测试机器的连接地址'),field('test-port','连接端口','2222','远程连接端口'),field('test-user','连接用户','developer','测试环境使用的账户')]},
 {id:'test-rules',name:'测试约定',path:'工作 / 测试环境',category:'项目资料',tag:'开发',description:'测试数据与联调窗口约定',fields:[field('test-window','联调时间','工作日 14:00–18:00','团队约定的联调时段')]},
 {id:'other',name:'归档项目入口',path:'工作 / 其他项目',category:'项目资料',tag:'常用',description:'已归档项目的信息入口',fields:[field('archive-url','访问地址','https://archive.example','项目归档页面')]},
 {id:'bio',name:'个人介绍',path:'个人',category:'个人信息',tag:'常用',description:'个人站点使用的简短介绍',fields:[field('bio-name','显示名称','林予安','对外展示名称'),field('bio-line','一句话介绍','记录开发与日常的个人站点','站点简介')]},
 {id:'contact',name:'联系信息',path:'个人',category:'个人信息',tag:'常用',description:'常用的公开联系渠道',fields:[field('contact-mail','联系邮箱','hello@personal.example','公开联络邮箱')]},
 {id:'home',name:'家庭网络',path:'家庭',category:'网络资料',tag:'自托管',description:'家庭设备的管理入口',fields:[field('home-url','管理入口','https://router.home.example','路由器管理入口')]}
 ];
 const request=(id,title,agent,kind,itemIds,time,state='待处理',purpose='')=>({id,title,agent,kind,itemIds,time,state,purpose:purpose||'核对工作所需的信息，并整理相关说明。',scope:kind==='整理资料'?itemIds.length+' 条信息':itemIds.reduce((n,id)=>n+items.find(i=>i.id===id).fields.length,0)+' 个字段'});
 const requests=[request('REQ-024','部署北辰文档站','Codex','读取信息',['docs','project'],'14:32','待处理','检查文档服务的部署配置，确认项目代号与访问入口，并更新部署说明。'),request('REQ-023','排查测试环境连接','Codex','读取信息',['test'],'14:28','待处理','核对测试服务器的连接地址、端口和账户，定位连接失败的原因。'),request('REQ-022','整理项目服务资料','Codex','整理资料',['docs','api','backup','monitor'],'14:25','待处理','按服务用途整理项目资料的目录和标签。'),request('REQ-021','补全个人站点介绍','Claude Code','读取信息',['bio'],'14:21'),request('REQ-020','核对备份任务配置','Codex','读取信息',['backup','deploy'],'14:18'),request('REQ-019','整理常用联系资料','Claude Code','整理资料',['bio','contact'],'14:17'),request('REQ-018','更新项目访问入口','Codex','读取信息',['api'],'13:50','已批准'),request('REQ-017','导出旧服务配置','Codex','读取信息',['docs','backup'],'13:42','已拒绝')];
 ['核对家庭网络配置','更新个人联系信息','检查归档服务入口','核对接口服务版本','确认测试联调时间','检查部署约定','整理个人站点资料','核对服务维护人','查找项目文档入口','检查备份存放位置','更新项目发布说明','核对项目代号','检查测试环境账户','确认常用联系渠道','核对监测服务入口','回看归档项目资料'].forEach((title,i)=>requests.push(request('REQ-'+String(16-i).padStart(3,'0'),title,'Codex','读取信息',[items[(i+3)%items.length].id],i<6?'昨天':'10月14日',i%4===0?'已拒绝':'已批准')));
 Alpine.data('workspace',()=>mergeViews({
 page:['library','credentials','proposals','history','settings'].includes(new URLSearchParams(location.search).get('page'))?new URLSearchParams(location.search).get('page'):'approvals',theme:['purple','green','blue','mono'].includes(new URLSearchParams(location.search).get('theme'))?new URLSearchParams(location.search).get('theme'):'purple',
 themes:[{id:'purple',name:'紫棠',color:'#82536b'},{id:'green',name:'松石',color:'#296a53'},{id:'blue',name:'雾蓝',color:'#496ea1'},{id:'mono',name:'黑白',color:'#333333'}],
 items,requests,requestId:'REQ-026',requestSearch:'',requestFilter:'all',requestPage:0,duration:'30',selection:['url','dir','code'],organizationSelection:[],
 filters:[{id:'all',name:'全部'},{id:'pending',name:'待处理'},{id:'done',name:'已处理'}],
 folder:'工作/北辰项目',itemId:'docs',itemSearch:'',expanded:['工作','工作/北辰项目'],
 tree:[{name:'工作',path:'工作',depth:0,children:true},{name:'北辰项目',path:'工作/北辰项目',depth:1,children:true},{name:'服务',path:'工作/北辰项目/服务',depth:2},{name:'项目资料',path:'工作/北辰项目/项目资料',depth:2},{name:'测试环境',path:'工作/测试环境',depth:1},{name:'其他项目',path:'工作/其他项目',depth:1},{name:'个人',path:'个人',depth:0},{name:'家庭',path:'家庭',depth:0}],
 init(){this.extraInit();this.credentialInit();this.$watch('requestId',()=>{this.selection=this.currentItems.flatMap(i=>i.fields.filter(f=>!f.secret).map(f=>f.id));this.organizationSelection=this.currentItems.map(i=>i.id);this.duration='30'})},
 get currentRequest(){return this.requests.find(r=>r.id===this.requestId)},
 get currentItems(){return this.currentRequest.itemIds.map(id=>this.items.find(i=>i.id===id))},
 get totalFields(){return this.currentItems.reduce((n,i)=>n+i.fields.length,0)},
 get selectedCount(){return this.currentItems.reduce((n,i)=>n+this.selectedFor(i),0)},
 selectedFor(item){return item.fields.filter(f=>this.selection.includes(f.id)).length},selectedNames(item){return item.fields.filter(f=>this.selection.includes(f.id)).map(f=>f.name).join('、')},
 requestCount(filter){return this.requests.filter(r=>filter==='all'||(filter==='pending'?r.state==='待处理':r.state!=='待处理')).length},
 get filteredRequests(){return this.requests.filter(r=>(this.requestFilter==='all'||(this.requestFilter==='pending'?r.state==='待处理':r.state!=='待处理'))&&[r.title,r.agent,...r.itemIds.map(id=>this.items.find(i=>i.id===id).name)].join(' ').toLowerCase().includes(this.requestSearch.toLowerCase()))},
 get visibleRequests(){return this.filteredRequests.slice(this.requestPage*8,this.requestPage*8+8)},get requestPages(){return Math.max(1,Math.ceil(this.filteredRequests.length/8))},get rangeLabel(){return this.filteredRequests.length?'显示 '+(this.requestPage*8+1)+'–'+Math.min(this.requestPage*8+8,this.filteredRequests.length)+' / '+this.filteredRequests.length+' 条':'0 条请求'},
 folderCount(path){return this.items.filter(i=>i.path.replaceAll(' / ','/').startsWith(path)).length},
 treeVisible(node){const parts=node.path.split('/');return parts.slice(0,-1).every((_,i)=>this.expanded.includes(parts.slice(0,i+1).join('/')))},toggleFolder(path){this.expanded=this.expanded.includes(path)?this.expanded.filter(p=>p!==path):[...this.expanded,path]},
 get filteredItems(){return this.items.filter(i=>(this.folder==='all'||i.path.replaceAll(' / ','/').startsWith(this.folder))&&(i.name+' '+i.description).includes(this.itemSearch)).sort((a,b)=>a.name.localeCompare(b.name,'zh-CN'))},
 get currentItem(){return this.items.find(i=>i.id===this.itemId)},pickFirstItem(){if(!this.filteredItems.some(i=>i.id===this.itemId)&&this.filteredItems.length)this.itemId=this.filteredItems[0].id}
 }));
});
