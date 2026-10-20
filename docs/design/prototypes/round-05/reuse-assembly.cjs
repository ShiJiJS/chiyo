const fs=require('node:fs'),path=require('node:path');
module.exports=html=>{
 const replace=(a,b)=>{if(!html.includes(a))throw Error('Reuse anchor missing: '+a.slice(0,80));html=html.replace(a,b)};
 replace('<script defer src="vendor/alpine.min.js"></script>','<script defer src="reuse.js"></script><script defer src="vendor/alpine.min.js"></script>');
 replace('<template x-if="historyResults.length&&grant.kind===\'凭据使用\'">',fs.readFileSync(path.join(__dirname,'reuse-history.html'),'utf8')+'<template x-if="historyResults.length&&grant.kind===\'凭据使用\'&&!grant.reusable">');
 html=html.replaceAll('由 CLI 启动什么命令','首条 CLI 命令参考').replaceAll('允许这次启动','批准期限内使用').replaceAll('仅一次，绑定当前会话。','期限内可重复使用，绑定当前会话。').replaceAll('按本页的凭据与启动内容执行。','固定凭据版本和使用方式；逐次命令独立记录。').replaceAll('允许启动的期限','使用授权期限').replaceAll('允许本次会话启动一次任务，使用「','允许本次会话在有效期内重复使用「');
 html=html.replace('程序、参数、工作目录或注入位置改变都需要重新申请。','同一批准范围内的新命令不重新审批；每次操作冻结自己的计划和操作ID。增加未批准的凭据或使用方式需要新申请。');
 html=html.replace('已批准 · 一次启动尝试','已批准 · 有效期内可重复使用').replace('启动尝试不会消费字段读取许可；单项撤销相互独立。','每次使用不会延长授权；普通字段读取默认8小时，与凭据使用期限独立；单项撤销相互独立。');
 html=html.replace('<span>各自到期</span><span x-text="useMinutes===\'15\'?\'今天 14:55\':\'今天 15:10\'"></span>','<span>使用授权到期</span><span x-text="useDecision[requestId]?.use?(useMinutes===\'15\'?\'今天 14:55\':\'今天 15:10\'):\'未批准\'"></span></div><div><span>普通字段到期</span><span x-text="useDecision[requestId]?.fields.length?\'今天 22:40\':\'未批准\'"></span>');
 html=html.replace("'字段许可独立生效，'+useMinutes+'分钟后到期；启动不消费字段许可。'","'普通字段独立授权，8小时后到期；凭据使用不消费该许可。'");
 html=html.replace('已批准，等待 Agent 调用','已批准，期限内可继续使用');
 return html;
};
