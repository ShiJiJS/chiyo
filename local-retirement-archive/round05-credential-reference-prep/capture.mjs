import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(fileURLToPath(import.meta.url));
const skillTool = 'C:/Users/Todoki/.agents/skills/oil-ui-pro/scripts/shoot.mjs';
const repo = 'C:/Project/network_config/info-manage';
const prototype = join(repo, 'docs/design/prototypes/round-05');
const sourceTool = await readFile(skillTool, 'utf8');

function measureReference() {
  const properties = ['display','position','width','height','minWidth','minHeight','maxWidth','maxHeight','boxSizing','gridTemplateColumns','gridTemplateRows','flex','flexDirection','alignItems','justifyContent','gap','rowGap','columnGap','padding','margin','fontFamily','fontSize','fontWeight','fontStyle','lineHeight','letterSpacing','color','backgroundColor','border','borderTop','borderRight','borderBottom','borderLeft','borderRadius','boxShadow','overflow','overflowX','overflowY','scrollbarGutter','opacity','backdropFilter','transform'];
  const selectors = ['.credential-library','.credential-side-button.active','.credential-detail','.credential-secret','.credential-facts','.credential-fact','.credential-links','.credential-link','.credential-notice','.credential-modal','.credential-form-options','.link-choice','.credential-request','.runtime-document','.runtime-section','.runtime-heading','.tip-toggle','.inline-tip','.injection-map','.file-reference','.command-preview','.launch-meta','.use-fields','.injection-boundary','.request-brief','.request-contract','.usage-flow','.cleanup-summary','body','.topbar','.brand','.brand svg','.topbar nav','.tab.active','.themes','.themes button.chosen','.connection','main.library-layout','.directory-panel','.directory-head','.directory-head h1','.directory-head .search','.library-mode','.tree-row.active','.directory-tools','.tree-scroll','.directory-footer','.item-list-panel','.item-list-head','.item-list-head h2','.item-list-head .quiet-button','.item-list','.info-row','.info-row.selected','.info-row h3','.info-row p','.info-meta','.info-icon','.row-arrow','.item-list-footer','.info-detail-area','.info-detail','.info-toolbar','.info-document','.detail-path','.info-title','.info-title h2','.info-title p','.large-icon','.item-properties','.info-fields','.read-field','.read-field strong','.read-field code','.associated-credentials','.public-info','.info-footer','main.new-layout','.queue','.queue-head','.queue-head h1','.queue-head .search','.filters','.filters .active','.queue-list','.queue-label','.request-row.selected','.row-title strong','.row-meta','.queue-footer','.approval-stage','.contextbar','.contextbar .quiet-button','.document-card','.document-body','.request-state','.document-heading','.identity','.document-lead','.review-heading','.draft-item','.draft-title','.draft-title h3','.draft-meta','.draft-field','.draft-field code','.document-actions','.document-actions .primary','.document-actions .secondary','.notice','.notice.warn','.diff-table','.diff-line','.diff-line.heading','.diff-before','.diff-after','.history-summary','.history-summary strong','.history-summary strong b','.inner-tabs','.inner-tabs .active','.scope-record','.scope-record h3','.scope-record .tag','.timeline','.event','.event header','.settings-layout','.settings-nav','.settings-nav h1','.settings-nav button.active','.settings-stage','.settings-page','.settings-page>header','.settings-page h2','.settings-block','.setting-row','.setting-row select','.color-options','.color-option','.color-option.chosen','.color-sample','.switch','.template-layout','.template-list','.template-detail','.template-field','.backup-intro','.modal-backdrop','.modal','.modal-head','.modal-head h2','.modal-actions','.modal-actions .primary','.modal-actions .secondary','.flow-modal','.flow-panel','.flow-scroll','.flow-grid','.flow-modal label','.flow-modal input','.flow-modal textarea','.flow-field','.flow-modal .modal-actions','.flow-error'];
  const visible = element => {
    const rect = element.getBoundingClientRect();
    const style = getComputedStyle(element);
    return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
  };
  const elements = {};
  for (const selector of selectors) {
    const matches = [...document.querySelectorAll(selector)].filter(visible).slice(0, 3);
    if (!matches.length) continue;
    elements[selector] = matches.map(element => {
      const rect = element.getBoundingClientRect(), style = getComputedStyle(element);
      return {
        tag: element.tagName, className: element.className?.baseVal ?? element.className,
        text: element.textContent.trim().replace(/\s+/g, ' ').slice(0, 120),
        rect: Object.fromEntries(['x','y','width','height','top','right','bottom','left'].map(key => [key, Math.round(rect[key] * 1000) / 1000])),
        scroll: {clientWidth:element.clientWidth,clientHeight:element.clientHeight,scrollWidth:element.scrollWidth,scrollHeight:element.scrollHeight,scrollTop:element.scrollTop},
        style: Object.fromEntries(properties.map(property => [property, style[property]])),
      };
    });
  }
  return {
    url: location.href,
    title: document.title,
    viewport: {width:innerWidth,height:innerHeight,dpr:devicePixelRatio,visualScale:visualViewport?.scale},
    userAgent: navigator.userAgent,
    fonts: [...document.fonts].map(font => ({family:font.family,weight:font.weight,status:font.status})),
    stylesheets: [...document.styleSheets].map(sheet => ({href:sheet.href,ruleCount:sheet.cssRules.length})),
    resources: performance.getEntriesByType('resource').map(entry => ({name:entry.name,duration:Math.round(entry.duration),transferSize:entry.transferSize,responseStatus:entry.responseStatus})),
    theme: Object.fromEntries(['accent','strong','selected','wash','base','paper','line','muted','text'].map(name => [name,getComputedStyle(document.body).getPropertyValue('--'+name).trim()])),
    elements,
  };
}

// The official screenshot logic stays intact. The external copy adds one
// read-only DOM evaluation after screenshot/lint, then stores it in report.json.
const originalEntry = 'entry = { file: basename(file), ...meta, animationWaitMs, issues, lint: hints };';
if (!sourceTool.includes(originalEntry)) throw new Error('Screenshot tool integration point changed');
const measuredTool = sourceTool.replace(originalEntry, 'entry = { file: basename(file), ...meta, animationWaitMs, issues, lint: hints, dom: await evaluate(`('+measureReference.toString()+')()`) };');
await writeFile(join(root, 'shoot-measured.mjs'), measuredTool);

const cases = [
  ['credential-file','page=credentials'],
  ['credential-string','page=credentials&state=token'],
  ['credential-expired','page=credentials&state=expired'],
  ['credential-add-string','page=credentials','click [aria-label="添加凭据"]'],
  ['credential-add-file','page=credentials','click [aria-label="添加凭据"]; click .credential-form-options button:has-text("文件")'],
  ['credential-rotate','state=credential-rotate'],
  ['credential-discovery','state=credential-discovery'],
  ['credential-links','page=library','click .associated-credentials .section-heading button'],
  ['server-linked','state=server'],
  ['use-string','state=use-token'],
  ['use-file','state=use-file'],
  ['use-file-env','state=file-env'],
  ['use-file-tip','state=use-file','click [aria-label="查看注入方式说明"]'],
  ['use-request','state=use-file','click .request-link'],
  ['use-file-confirm','state=use-file','click .credential-request .decision-actions .primary'],
  ['use-string-confirm','state=use-token','click .credential-request .decision-actions .primary'],
  ['execution-running','state=execution-running'],
  ['execution-prepare-failed','state=execution-prepare_failed'],
  ['execution-start-failed','state=execution-start_failed'],
  ['execution-nonzero','state=execution-nonzero'],
  ['execution-unknown','state=execution-unknown'],
  ['execution-token','state=execution-token'],
  ['execution-cleanup-failed','state=cleanup'],].map(([id,query,steps]) => ({id,query:'theme=purple&'+query,steps:steps||''}));
await writeFile(join(root,'capture-matrix.json'),JSON.stringify(cases,null,2));
const hashes = {};
let cascade = '';
for (const name of ['index.html','prototype.css','sections.css','credentials.css','runtime.css','lifecycle.css','prototype.js','sections.js','credentials.js','runtime.js','lifecycle.js','fonts/NotoSansSC-Regular.otf']) {
  const bytes = await readFile(join(prototype,name));
  hashes[name] = createHash('sha256').update(bytes).digest('hex');
  if(name.endsWith('.css')) cascade += '\n\n/* '+name+' */\n'+bytes.toString().replaceAll('}', '}\n');
}
await writeFile(join(root,'source-sha256.json'),JSON.stringify({prototype,skillTool,skillToolSha256:createHash('sha256').update(sourceTool).digest('hex'),files:hashes},null,2));
await writeFile(join(root,'css-source-order.txt'),cascade);

const requested = process.argv.slice(2);
if (requested.includes('--prepare-only')) process.exit(0);
const selected = requested.length ? cases.filter(entry=>requested.includes(entry.id)) : cases;
for (const entry of selected) {
  const output = join(root,'cases',entry.id);
  await mkdir(output,{recursive:true});
  const args = [join(root,'shoot-measured.mjs'),'http://127.0.0.1:8797/index.html','--query',entry.query,'--size','1440x900,1280x800','--out',output];
  if(entry.steps) args.push('--steps',entry.steps);
  console.log('\nCASE '+entry.id);
  await writeFile(join(output,'command.json'),JSON.stringify({executable:process.execPath,args},null,2));
  const exitCode = await new Promise(resolve => {
    const child = spawn(process.execPath,args,{cwd:root,stdio:'inherit'});
    child.on('exit',resolve);
  });
  if(exitCode !== 0) throw new Error(entry.id+' failed with '+exitCode);
}
