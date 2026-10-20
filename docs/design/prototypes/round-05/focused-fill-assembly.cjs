const fs=require('node:fs'),path=require('node:path');
module.exports=html=>{
 const replace=(a,b)=>{if(!html.includes(a))throw Error('Focused-fill anchor missing: '+a.slice(0,80));html=html.replace(a,b)};
 const fragment=name=>fs.readFileSync(path.join(__dirname,'focused-fill-'+name+'.html'),'utf8');
 replace('<script defer src="vendor/alpine.min.js"></script>','<script defer src="focused-fill.js"></script><script defer src="vendor/alpine.min.js"></script>');
 replace('</head>','<link rel="stylesheet" href="focused-fill.css">\n</head>');
 replace('<template x-if="currentRequest.kind===\'使用凭据\'">',fragment('approval')+'<template x-if="currentRequest.kind===\'使用凭据\'&&!isFocusedFill">');
 replace('<template x-if="historyResults.length&&grant.kind===\'凭据使用\'&&grant.reusable">',fragment('history')+'<template x-if="historyResults.length&&grant.kind===\'凭据使用\'&&grant.reusable&&!grant.focusedFill">');
 replace('</body></html>',fragment('dialog')+'\n</body></html>');
 return html;
};
