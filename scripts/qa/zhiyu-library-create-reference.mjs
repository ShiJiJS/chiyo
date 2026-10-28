import {mkdir, readFile, writeFile} from 'node:fs/promises';
import {dirname, isAbsolute} from 'node:path';
import {createHash} from 'node:crypto';

export function inspectLibraryCreate() {
  const selectors = {
    surface: '.modal',
    'desktop-dialog-close': '.modal-head button',
    'library-create-intro': '.chooser-intro',
    'library-create-open-plugins': '.chooser-bottom button',
  };
  for (const id of ['server', 'service', 'profile', 'generic', 'document', 'file', 'credential']) {
    selectors['library-new-type-' + id] = `[data-new-template="${id}"], [data-core-new="${id}"]`;
  }
  const boxes = {};
  for (const [id, selector] of Object.entries(selectors)) {
    const e = document.querySelector(selector);
    if (!e) throw new Error('Missing chooser element: ' + id);
    const r = e.getBoundingClientRect();
    boxes[id] = {x: r.x, y: r.y, width: r.width, height: r.height};
  }
  return {
    viewport: {width: innerWidth, height: innerHeight, dpr: devicePixelRatio},
    theme: document.body.dataset.theme,
    font: getComputedStyle(document.body).fontFamily,
    state: {page: ROUND9.state.page, directory: ROUND9.state.dir},
    labels: [...document.querySelectorAll('.template-choice,.core-choices button')].map(e => e.textContent.trim()),
    boxes,
  };
}

export async function captureLibraryCreate(page, {width, height, theme, output}) {
  if (![1440, 1280].includes(width) || height !== (width === 1440 ? 900 : 800) ||
      !['light', 'dark'].includes(theme) || !isAbsolute(output)) throw new Error('Explicit capture conditions required');
  await mkdir(dirname(output), {recursive: true});
  await page.cdp('Emulation.setDeviceMetricsOverride', {width, height, deviceScaleFactor: 1, mobile: false});
  if (await page.evaluate(() => !!document.querySelector('.modal'))) await page.click('button[aria-label="关闭"]');
  await page.click('button[data-page="settings"]');
  await page.click(`button[data-theme="${theme}"]`);
  await page.click('button[data-page="library"]');
  await page.click('button[aria-label="添加资料"]');
  await page.waitForSelector('#toast-root .toast', {state: 'hidden'});
  await page.waitForFunction(() => document.fonts.status === 'loaded' && !document.getAnimations().some(a => a.playState === 'running'));
  const before = await page.evaluate(inspectLibraryCreate);
  await page.screenshot({path: output + '.png'});
  const after = await page.evaluate(inspectLibraryCreate);
  const errors = [];
  if (JSON.stringify(before) !== JSON.stringify(after)) errors.push('state_changed');
  if (JSON.stringify(after.viewport) !== JSON.stringify({width, height, dpr: 1})) errors.push('viewport');
  if (after.theme !== theme || after.state.page !== 'library' || after.state.directory !== 'selfhost') errors.push('state');
  if (!after.font.includes('Zhiyu System') || !after.font.includes('PingFang SC')) errors.push('fonts');
  const report = {before, after, accepted: !errors.length, errors,
    imageSha256: createHash('sha256').update(await readFile(output + '.png')).digest('hex'),
    scope: 'Frozen chooser; not full S5 or actual OS input', fullS5Passed: false};
  await writeFile(output + '.json', JSON.stringify(report, null, 2) + '\n');
  if (errors.length) throw new Error('Rejected chooser capture: ' + errors.join(', '));
  return report;
}
