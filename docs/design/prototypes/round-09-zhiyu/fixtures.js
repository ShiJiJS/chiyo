/* All values are fictional. This prototype never connects to the installed app. */
window.LIBRARY = {
  groups: [
    {id:'all',name:'全部资料',icon:'grid'},
    {id:'servers',name:'服务器与设备',icon:'server',parent:'技术资源'},
    {id:'services',name:'应用与服务',icon:'layers',parent:'技术资源'},
    {id:'telegram',name:'Telegram',icon:'send',parent:'技术资源'},
    {id:'profile',name:'个人档案',icon:'user',parent:'个人资料'},
    {id:'career',name:'求职材料',icon:'briefcase',parent:'个人资料'},
    {id:'docs',name:'操作文档',icon:'book',parent:'按内容查看'},
    {id:'credentials',name:'凭据',icon:'key',parent:'按内容查看'}
  ],
  items: [
    {id:'azure',name:'Azure 日本服务器',kind:'server',category:'servers',summary:'公网入口 · 域名与 HTTPS 反向代理',subtitle:'东京 · Ubuntu 24.04',updated:'10月22日',fields:[['主机地址','tokyo.beichen.example'],['SSH 端口','2222'],['登录用户','developer'],['服务器用途','HTTPS 入口与反向代理']],docs:['https','sshguide'],credentials:['sshkey'],related:['aliyun','vikunja','blinko'],tags:['日本','公网入口']},
    {id:'aliyun',name:'阿里云杭州服务器',kind:'server',category:'servers',summary:'业务服务 · 应用容器与数据存储',subtitle:'杭州 · Ubuntu 24.04',updated:'10月21日',fields:[['主机地址','hangzhou.beichen.example'],['SSH 端口','22'],['登录用户','operator'],['服务器用途','运行自托管应用']],docs:['deploy'],credentials:['aliyunkey'],related:['azure','blinko','sparky'],tags:['杭州','应用部署']},
    {id:'nas',name:'极空间 NAS',kind:'server',category:'servers',summary:'家庭存储 · 视频资源与备份',subtitle:'家庭网络 · SSH',updated:'10月20日',fields:[['主机地址','nas.home.example'],['SSH 端口','22'],['登录用户','media'],['服务器用途','媒体存储与本地备份']],docs:['nasdoc'],credentials:[],related:['video','syncthing'],tags:['家庭','存储']},
    {id:'blinko',name:'Blinko 笔记',kind:'service',category:'services',summary:'随手记录与饮食笔记',subtitle:'部署于阿里云杭州',updated:'10月22日',fields:[['访问入口','https://notes.beichen.example'],['部署位置','阿里云杭州服务器'],['认证方式','API Token'],['日常用途','记录笔记、检索饮食记录']],docs:['deploy'],credentials:['blinkokey'],related:['aliyun','azure'],tags:['笔记']},
    {id:'vikunja',name:'Vikunja 任务管理',kind:'service',category:'services',summary:'项目任务、进度与协作',subtitle:'部署于阿里云杭州',updated:'10月21日',fields:[['访问入口','https://tasks.beichen.example'],['部署位置','阿里云杭州服务器'],['认证方式','Agent API Token'],['日常用途','管理项目与任务']],docs:['deploy'],credentials:['vikunjakey'],related:['aliyun','azure'],tags:['任务管理']},
    {id:'sparky',name:'SparkyFitness',kind:'service',category:'services',summary:'饮食、运动与健康记录',subtitle:'部署于阿里云杭州',updated:'10月20日',fields:[['访问入口','https://fitness.beichen.example'],['部署位置','阿里云杭州服务器'],['认证方式','API Key']],docs:['deploy'],credentials:[],related:['aliyun','blinko'],tags:['健康']},
    {id:'skillshare',name:'Skillshare',kind:'service',category:'services',summary:'技能仓库与跨设备分发',subtitle:'私有服务',updated:'10月19日',fields:[['访问入口','https://skills.beichen.example'],['仓库','beichen/agent-skills'],['同步方式','Git over SSH']],docs:['deploy'],credentials:[],related:['aliyun'],tags:['开发工具']},
    {id:'video',name:'Video Viewer',kind:'service',category:'services',summary:'浏览 NAS 中的视频资源',subtitle:'部署于家庭 NAS',updated:'10月20日',fields:[['访问入口','https://video.home.example'],['部署位置','极空间 NAS'],['媒体目录','/data/media']],docs:['nasdoc'],credentials:[],related:['nas'],tags:['媒体']},
    {id:'syncthing',name:'Syncthing',kind:'service',category:'services',summary:'个人资料的设备间同步',subtitle:'桌面端 ↔ NAS',updated:'10月18日',fields:[['同步对象','个人资料'],['设备','桌面端与家庭 NAS'],['用途','保持资料副本一致']],docs:['nasdoc'],credentials:[],related:['nas'],tags:['同步']},
    {id:'tgapi',name:'Telegram 开发者应用',kind:'service',category:'telegram',summary:'应用登记与客户端初始化',subtitle:'API 应用资料',updated:'10月21日',fields:[['应用名称','Beichen Assistant'],['API ID','12345678'],['应用用途','资源整理客户端']],docs:[],credentials:['tgsession'],related:['mtproto','workflow'],tags:['Telegram']},
    {id:'mtproto',name:'Telegram MTProto 服务器',kind:'service',category:'telegram',summary:'测试、生产连接参数与服务器公钥',subtitle:'公钥附件 · PEM',updated:'10月22日',fields:[['测试环境','test.dc.example:443'],['生产环境','production.dc.example:443'],['公钥用途','验证服务器身份，不是登录凭据']],docs:['publickey'],credentials:[],related:['tgapi'],tags:['Telegram']},
    {id:'workflow',name:'Telegram 资源整理',kind:'document',category:'telegram',summary:'收件、下载与归档的工作步骤',subtitle:'工作流 · Markdown',updated:'10月20日',owner:'tgapi',tags:['工作流']},
    {id:'profile',name:'个人档案',kind:'profile',category:'profile',summary:'基本信息、教育和工作经历',subtitle:'按经历分组 · 逐项授权',updated:'10月22日',tags:['求职'],docs:['resume','proof'],credentials:[],related:[]},
    {id:'resume',name:'服务端开发简历',kind:'resume',category:'career',summary:'中文 · 服务端研发岗位',subtitle:'PDF · 465 KB · 2 个版本',updated:'10月22日',version:'v2',filename:'林予安-服务端开发-v2.pdf',tags:['中文','服务端'],related:['profile','proof'],credentials:[]},
    {id:'resume-en',name:'英文简历',kind:'resume',category:'career',summary:'英文 · Backend Engineer',subtitle:'PDF · 320 KB · 1 个版本',updated:'10月18日',version:'v1',filename:'Yuan-Lin-Backend.pdf',tags:['英文','服务端'],related:['profile'],credentials:[]},
    {id:'proof',name:'实习证明',kind:'file',category:'career',summary:'研发实习经历的证明材料',subtitle:'PDF · 180 KB',updated:'10月16日',filename:'研发实习证明.pdf',related:['profile'],tags:['证明材料']},
    {id:'offer',name:'录用通知书',kind:'file',category:'career',summary:'录用岗位、入职日期与约定',subtitle:'PDF · 210 KB',updated:'10月15日',filename:'录用通知书.pdf',related:['profile'],tags:['证明材料']},
    {id:'portrait',name:'证件照',kind:'file',category:'career',summary:'蓝底 · 1:1 · 用于招聘网站',subtitle:'PNG · 800 × 800',updated:'10月15日',filename:'证件照-方形.png',related:['profile'],tags:['照片']},
    {id:'https',name:'域名与 HTTPS',kind:'document',category:'docs',summary:'DNS、反向代理与新增服务的操作说明',subtitle:'Azure 日本服务器 · Markdown',updated:'10月22日',owner:'azure',tags:['运维','HTTPS']},
    {id:'sshguide',name:'SSH 连接与维护',kind:'document',category:'docs',summary:'连接步骤、主机校验与常见故障',subtitle:'Azure 日本服务器 · Markdown',updated:'10月21日',owner:'azure',tags:['运维']},
    {id:'deploy',name:'自托管服务部署',kind:'document',category:'docs',summary:'容器部署、数据目录与更新流程',subtitle:'阿里云杭州服务器 · Markdown',updated:'10月20日',owner:'aliyun',tags:['运维']},
    {id:'nasdoc',name:'NAS 与媒体目录',kind:'document',category:'docs',summary:'共享目录、访问方式与备份',subtitle:'极空间 NAS · Markdown',updated:'10月18日',owner:'nas',tags:['存储']},
    {id:'publickey',name:'MTProto 服务器公钥',kind:'file',category:'telegram',summary:'测试和生产环境的 RSA 公钥',subtitle:'PEM / PKCS#1 · 公开认证材料',updated:'10月22日',filename:'telegram-server-public.pem',owner:'mtproto',related:['mtproto'],tags:['公钥']},
    {id:'sshkey',name:'Azure SSH 私钥',kind:'credential',category:'credentials',summary:'登录 Azure 日本服务器',subtitle:'PEM / RSA · 支持 SSH 注入',updated:'10月21日',owner:'azure',format:'PEM / RSA',filename:'azure-jp.pem',capability:'可用于 SSH',binding:'SSH_KEY_FILE',tags:['SSH']},
    {id:'aliyunkey',name:'阿里云 SSH 私钥',kind:'credential',category:'credentials',summary:'登录阿里云杭州服务器',subtitle:'OpenSSH · 支持 SSH 注入',updated:'10月20日',owner:'aliyun',format:'OpenSSH',filename:'aliyun_ed25519',capability:'可用于 SSH',binding:'SSH_KEY_FILE',tags:['SSH']},
    {id:'blinkokey',name:'Blinko API Token',kind:'credential',category:'credentials',summary:'通过 API 读取和创建笔记',subtitle:'字符串 · 环境变量',updated:'10月21日',owner:'blinko',format:'Token 字符串',capability:'可注入环境变量',binding:'BLINKO_TOKEN',tags:['API']},
    {id:'vikunjakey',name:'Vikunja Agent Token',kind:'credential',category:'credentials',summary:'管理指定项目的任务',subtitle:'字符串 · 环境变量',updated:'10月20日',owner:'vikunja',format:'Token 字符串',capability:'可注入环境变量',binding:'VIKUNJA_TOKEN',tags:['API']},
    {id:'tgsession',name:'Telethon 登录会话',kind:'credential',category:'credentials',summary:'保留 Telegram 客户端的登录状态',subtitle:'SQLite / .session · 仅保管',updated:'10月21日',owner:'tgapi',format:'SQLite / .session',filename:'telegram-client.session',capability:'尚未支持使用',binding:'',tags:['登录会话']}
  ]
};
