// Run from the repository root: node scripts/export-filling-explainer.mjs
// EGO_PDF_SPACE may name an existing task space; the script leaves it available for review.
const fs = await import('node:fs/promises');
const path = await import('node:path');
if (typeof taskSpace === 'undefined') {
  const {spawnSync}=await import('node:child_process');
  const source=await fs.readFile(new URL(import.meta.url),'utf8');
  const setup=`globalThis.exportRoot=${JSON.stringify(process.cwd())};globalThis.exportSpace=${JSON.stringify(process.env.EGO_PDF_SPACE || null)};\n`;
  const result=spawnSync('ego-browser',['nodejs'],{input:setup+source,encoding:'utf8',stdio:['pipe','inherit','inherit']});
  if(result.error)throw result.error;
  process.exit(result.status ?? 1);
}
const root = globalThis.exportRoot;
const dir = path.join(root, 'docs/explainers/credential-filling');
const task = await taskSpace(globalThis.exportSpace ? Number(globalThis.exportSpace) : '知予图解 PDF');
const page = task.page('p1');
await page.goto('file://' + path.join(dir, 'index.html'));
await page.waitForFunction(() => window.Alpine && document.querySelector('iframe')?.contentDocument?.querySelector('#password'));
// Freeze each platform after rendering its full teaching state, before removing Alpine bindings.
async function capture(os) {
  await page.evaluate(async (os) => {
    const state = Alpine.$data(document.body);
    state.setOS(os); state.scanNativeTargets(); state.selectNativeTask();
    state.demoBrowserFill();
    await Alpine.nextTick();
    document.querySelectorAll('details').forEach(e => e.open = true);
  }, os);
  return page.evaluate(() => {
    const clone = document.querySelector('main').cloneNode(true);
    // Hidden switch alternatives and template source are omitted; rendered alternatives remain.
    clone.querySelectorAll('template,script,[style*="display: none"]').forEach(e => e.remove());
    clone.querySelectorAll('*').forEach(e => {
      for (const a of [...e.attributes]) if (/^(x-|@|:)/.test(a.name)) e.removeAttribute(a.name);
    });
    return clone.innerHTML;
  });
}
const mac = await capture('mac');
const win = await capture('win');
await page.evaluate(({mac, win}) => {
  const main = document.querySelector('main');
  Alpine.destroyTree(document.body);
  document.body.removeAttribute('x-data');
  main.innerHTML = mac;
  main.querySelectorAll('#native > .reading h2,#platform > .reading h2').forEach(h => h.append('（Mac）'));
  const alternate = document.createElement('div'); alternate.innerHTML = win;
  for (const id of ['native','platform']) {
    const section = alternate.querySelector('#'+id);
    section.querySelector('h2').append('（Windows）');
    section.querySelectorAll('[id]').forEach(e => e.id += '-windows');
    section.id += '-windows'; main.append(section);
  }
  // Shared command execution and security chapters follow both native platform examples.
  for (const id of ['command-execution', 'security-boundary']) {
    const section = main.querySelector('#'+id);
    if (section) main.append(section);
  }
  document.querySelectorAll('footer,.topbar,.reading-toc,.toc-scrim,.skip,.os-selector,.native-window-tabs,.native-demo-actions,.choice-row,.query-run button,.fill-action button,.text-button').forEach(e=>e.remove());
  // Repository references must remain usable after downloading the PDF.
  main.querySelectorAll('a[href]').forEach(a => {
    const href = a.getAttribute('href');
    if (href && !href.startsWith('#') && !/^[a-z]+:/i.test(href)) {
      a.href = new URL(href, 'https://github.com/ShiJiJS/chiyo/blob/main/docs/explainers/credential-filling/index.html').href;
    }
  });
  document.querySelectorAll('details').forEach(e=>e.open=true);
  const note=document.createElement('p');note.className='pdf-note';
  note.textContent='静态阅读版 · 网页演示已展开为查询与填写结果；原生控件示例已展开为候选筛选与目标选择。第 04、05 章先呈现 Mac，再呈现 Windows；第 06 章合并说明单次命令、SSH 私钥登录与 SSH 密码长连接，第 07 章说明安全边界。专用 SSH 内置密码适配与持续 Shell 仍为待实现设计；通用执行配合 Expect 的密码登录已有能力。完整交互请打开配套 HTML 页面。';
  main.querySelector('.intro').append(note);
}, {mac,win});
const css=await fs.readFile(path.join(dir,'print.css'),'utf8');
await page.evaluate(css=>{const s=document.createElement('style');s.textContent=css;document.head.append(s);},css);
await page.cdp('Emulation.setEmulatedMedia',{media:'print'});
await page.waitForFunction(() => document.querySelector('iframe')?.contentDocument?.querySelector('#password'));
await page.evaluate(()=>document.fonts.ready);
const pdf=await page.cdp('Page.printToPDF',{
  printBackground:true, paperWidth:11.69,paperHeight:16.54,
  marginTop:.5,marginBottom:.55,marginLeft:.5,marginRight:.5,
  displayHeaderFooter:true,
  headerTemplate:'<div></div>',
  footerTemplate:'<div style="font:9px sans-serif;width:100%;text-align:center;color:#56645f">知予 · 凭据使用机制图解　<span class="pageNumber"></span> / <span class="totalPages"></span></div>',
  generateDocumentOutline:true
});
await fs.writeFile(path.join(dir,'credential-filling.pdf'),Buffer.from(pdf.data,'base64'));
console.log({space:task.spaceId,pdf:path.join(dir,'credential-filling.pdf')});
if (!globalThis.exportSpace) await task.finish({keep:[]});
