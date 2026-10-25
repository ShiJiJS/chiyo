/* Fictional data for a complete desktop walkthrough; no application connection. */
(function(){
const m=MODEL;
m.items.push({id:'github-token',name:'GitHub 仓库 Token',summary:'查看 northstar/agent-skills 仓库与事项；授权范围仅限该仓库',kind:'credential',directory:'selfhost',tags:['代码仓库'],format:'Token 字符串',binding:'GH_TOKEN',owner:'ideas',relations:{},values:{}});
m.items.push({id:'vikunja-password',name:'Vikunja 登录密码',summary:'任务管理网页登录使用，与 Agent API Token 分开保管',kind:'credential',directory:'selfhost',tags:['任务管理'],format:'密码字符串',binding:'当前输入焦点',delivery:'focus',owner:'vikunja',relations:{},values:{}});
m.items.find(i=>i.id==='vikunja').relations.credentials.push('vikunja-password');
m.items.forEach((i,n)=>{i.updatedAt='2026-10-'+String(23-n%12).padStart(2,'0');i.tags=[...(i.tags||[])];if(['azure','aliyun'].includes(i.id))i.tags.push('生产环境');if(i.id==='nas')i.tags.push('家庭');});
const server=m.presets[0].templates[0];
server.fields.push({key:'environment',label:'运行环境',type:'text',required:false},{key:'region',label:'地区',type:'text',required:false});
server.sections[0].keys.push('environment','region');
for(const i of m.items.filter(i=>i.templateId==='server')){i.definition=m.clone(server);i.values.environment=i.id==='nas'?'家庭':'生产';i.values.region=i.id==='azure'?'日本 · 东京':i.id==='aliyun'?'中国 · 杭州':'中国 · 上海';}
m.tags=[...new Set(m.items.flatMap(i=>i.tags))];
m.settings={theme:'light',notifications:true,wait:'30 分钟',retention:'180 天',tray:true};
m.proposals=[
 {id:'import',title:'补充北辰服务域名',type:'新增资料',status:'待确认',time:'今天 15:12',agent:'Codex',summary:'将维护文档中独立的域名信息整理为一条资料，关联已有服务器。',name:'北辰服务入口',directory:'selfhost',tags:['公网入口','生产环境'],fields:[['访问入口','https://portal.beichen.example'],['用途','集中访问自托管服务']],source:'服务维护记录',template:'应用与服务'},
 {id:'update',title:'更新杭州服务器连接说明',type:'修改信息',status:'待确认',time:'今天 14:58',agent:'Codex',summary:'SSH 端口已调整，同步连接字段；保留已有凭据与维护文档。',item:'aliyun',before:'22',after:'2222',baseVersion:1},
 {id:'organized',title:'整理自托管服务资料',type:'分类整理',status:'已完成',time:'昨天 18:20',agent:'Codex',summary:'已在获准范围内更新目录与标签，未改动字段内容。',items:['blinko','vikunja','sparky']}
];
m.history=[{id:'grant-ssh',title:'检查反向代理服务',type:'凭据使用',state:'有效',agent:'Codex',time:'今天 14:32',ttl:'剩余 24 分钟',item:'sshkey',scope:['Azure SSH 私钥 · CLI 临时文件','-i {{SSH_KEY_FILE}}','仅本会话，授权期内可重复使用'],events:[['14:32','批准凭据使用，期限 30 分钟'],['14:33','CLI 执行完成 · 退出码 0'],['14:36','复用授权 · 第二次执行完成']]},{id:'grant-file',title:'填写招聘网站资料',type:'文件领取',state:'有效',agent:'Codex',time:'今天 14:10',ttl:'剩余 8 分钟',item:'resume',scope:['个人简历 · v2 · PDF','联系邮箱'],events:[['14:10','批准领取文件与读取邮箱'],['14:11','文件副本已交付'],['14:12','读取联系邮箱']]},{id:'grant-fill',title:'登录任务管理',type:'焦点填充',state:'已结束',agent:'Codex',time:'昨天 19:10',ttl:'已到期',item:'vikunja-password',scope:['任务管理登录凭据','本机焦点填充 · 由用户核对目标'],events:[['19:10','批准使用'],['19:11','填充已完成'],['19:40','授权到期']]},{id:'grant-read',title:'查询服务访问入口',type:'字段读取',state:'已结束',agent:'Claude Code',time:'昨天 16:20',ttl:'会话结束',item:'blinko',scope:['Blinko 笔记 · 访问入口'],events:[['16:20','批准 1 个字段'],['16:21','读取 2 次'],['16:40','会话结束，授权失效']]},{id:'grant-org',title:'整理自托管服务资料',type:'分类整理',state:'已结束',agent:'Codex',time:'昨天 18:20',ttl:'整理完成',item:'blinko',scope:['3 项资料的目录与标签','仅元数据，允许在批准范围内自动应用'],events:[['18:00','批准整理 3 项资料'],['18:20','完成目录与标签整理']]}];
m.trash=[{id:'retired-doc',name:'旧部署笔记',summary:'已迁移到新的维护文档',kind:'document',directory:'selfhost',tags:['归档'],values:{body:'旧的容器部署步骤。'},deletedAt:'2026-10-20',relations:{}}];
})();
