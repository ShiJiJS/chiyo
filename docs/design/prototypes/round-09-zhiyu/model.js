/* Fictional records. Packages describe fields and layout; records own their data. */
(function(){
const clone=x=>JSON.parse(JSON.stringify(x));
const field=(key,label,type='text',required=false)=>({key,label,type,required});
const rel=(key,label,target=[])=>({key,label,targetTemplates:target});
const common=[rel('docs','文档与附件'),rel('credentials','关联凭据'),rel('related','相关资料')];
const server={id:'server',name:'服务器信息',icon:'server',fields:[field('host','主机地址','text',true),field('port','SSH 端口','number'),field('user','登录用户'),field('purpose','服务器用途')],sections:[{kind:'fields',title:'连接概览',keys:['host','port','user','purpose']},{kind:'relations',key:'credentials',title:'登录凭据'},{kind:'relations',key:'docs',title:'维护文档'},{kind:'relations',key:'related',title:'运行的应用与相关设备'}],relations:common,instructions:'先查找已有服务器；将连接参数、维护文档与登录凭据分别保存并明确关联。不要从名字或密钥片段猜测关联。不要求先建立目录。'};
const service={id:'service',name:'应用与服务',icon:'layers',fields:[field('url','访问入口','url'),field('purpose','应用用途'),field('auth','认证方式')],sections:[{kind:'fields',title:'服务概览',keys:['url','purpose','auth']},{kind:'relations',key:'hostedOn',title:'部署位置'},{kind:'relations',key:'credentials',title:'认证凭据'},{kind:'relations',key:'docs',title:'操作说明'}],relations:[rel('hostedOn','部署在',['server']),...common],instructions:'先记录应用名称、用途和入口。部署位置未知时留空；外部托管应用无需创建服务器。只有来源明确时才关联已有服务器；Token 独立保存在凭据中。'};
const profile={id:'profile',name:'个人档案',icon:'user',fields:[field('name','姓名'),field('email','联系邮箱'),field('direction','求职方向'),field('city','所在城市'),field('education','教育经历','entries'),field('experience','工作经历','entries')],sections:[{kind:'fields',title:'基本信息',keys:['name','email','direction','city']},{kind:'timeline',key:'education',title:'教育经历'},{kind:'timeline',key:'experience',title:'工作经历'},{kind:'relations',key:'docs',title:'简历与证明'}],relations:common,instructions:'学校、学历、专业和日期按每段经历成组。简历文件独立保存，通过关联进入；真实版本关系需要核对内容，不能只根据文件名判断。'};
const pack=(id,name,description,template)=>({id,name,version:'1.0.0',hostApi:1,author:'知予',origin:'内置',enabled:true,description,templates:[template]});
const presets=[pack('builtin.server','服务器信息','连接参数、维护文档与登录凭据，一处查找。',server),pack('builtin.service','应用与服务','记录访问入口、用途及可选的部署关系。',service),pack('builtin.profile','个人档案','按经历组织个人资料，关联简历与证明。',profile)];
const domainPackage={id:'local.domain',name:'域名管理',version:'1.0.0',hostApi:1,author:'本机 Agent',description:'记录域名、续费时间与 DNS 配置，按需关联服务器。',templates:[{id:'domain',name:'域名',icon:'globe',fields:[field('domain','域名','text',true),field('registrar','注册商'),field('expires','到期日期','date'),field('dns','DNS 服务'),field('purpose','域名用途')],sections:[{kind:'fields',title:'域名概览',keys:['domain','registrar','expires','dns']},{kind:'text',key:'purpose',title:'用途说明'},{kind:'relations',key:'pointsTo',title:'指向的服务器'}],relations:[rel('pointsTo','指向服务器',['server'])],instructions:'先按完整域名检索已有资料，避免重复录入。注册商与 DNS 服务分别填写；没有到期日期时留空，不推测。关联服务器需要明确依据，可以暂不关联。认证材料作为独立托管凭据，不写入域名字段。',example:{name:'北辰服务域名',summary:'统一访问个人自托管服务',values:{domain:'beichen.example',registrar:'示范注册商',expires:'2027-06-18',dns:'托管 DNS',purpose:'为笔记、任务管理与健康记录提供统一入口。'}}}]};
const dirs=[{id:'all',name:'全部资料',icon:'grid'},{id:'selfhost',name:'自托管服务',icon:'folder'},{id:'home',name:'家庭与设备',icon:'folder'},{id:'telegram',name:'Telegram 工具',icon:'folder'},{id:'personal',name:'个人资料',icon:'folder'},{id:'career',name:'求职材料',parent:'personal',icon:'folder'},{id:'unfiled',name:'未分类',icon:'folder'}];
function dirFor(i){if(['nas','video','syncthing','nasdoc'].includes(i.id))return 'home';if(i.category==='telegram'||i.id==='tgsession')return 'telegram';if(i.category==='career')return 'career';if(i.id==='profile')return 'personal';return 'selfhost'}
const items=LIBRARY.items.map(i=>{
 const t=i.kind==='server'?server:i.kind==='service'?service:i.kind==='profile'?profile:null;
 const p=t&&presets.find(p=>p.templates[0].id===t.id);
 let values={};
 if(i.kind==='server')t.fields.forEach((f,n)=>values[f.key]=i.fields[n]?.[1]||'');
 else if(i.kind==='service'){values={url:i.fields.find(f=>f[0]==='访问入口')?.[1]||'',purpose:i.summary,auth:i.fields.find(f=>f[0]==='认证方式')?.[1]||''};i.fields.filter(f=>!['访问入口','认证方式','部署位置','日常用途'].includes(f[0])).forEach((f,n)=>values['extra'+n]=f[1])}
 else if(i.kind==='profile')values={name:'林予安',email:'yuan.lin@example.com',direction:'服务端研发',city:'上海',education:[{title:'北辰大学 · 计算机技术硕士',period:'2024.09 — 2027.06',detail:'信息学院 · 分布式系统方向'},{title:'南川大学 · 软件工程学士',period:'2020.09 — 2024.06',detail:'计算机学院 · GPA 3.7 / 4.0'}],experience:[{title:'后端研发实习',period:'2026.04 — 2026.08',detail:'参与任务调度与服务监控开发。'}]};
 const definition=t&&clone(t);
 if(i.kind==='service')i.fields.filter(f=>!['访问入口','认证方式','部署位置','日常用途'].includes(f[0])).forEach((f,n)=>{definition.fields.push(field('extra'+n,f[0]));definition.sections[0].keys.push('extra'+n)});
 const relations={docs:i.docs||[],credentials:i.credentials||[],related:i.related||[]};
 if(i.kind==='service'){relations.hostedOn=(i.related||[]).filter(id=>['aliyun','nas'].includes(id));}
 if(i.id==='profile')relations.docs=['resume','resume-en','proof','portrait'];
 return {...i,directory:dirFor(i),templateId:t?.id||null,packageId:p?.id||null,templateVersion:p?.version||null,definition,values,relations};
});
items.push({id:'ideas',name:'下一次整理的想法',summary:'尚未分类的几条工作记录',directory:'unfiled',kind:'note',templateId:null,values:{body:'先梳理服务用途，再补充维护文档。没有合适模板的资料，可以先保存为通用信息。'},relations:{},tags:[]});
window.MODEL={presets,domainPackage,dirs,items,clone};
})();
