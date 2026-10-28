import {mkdir, writeFile, readFile} from 'node:fs/promises';
import {dirname, isAbsolute} from 'node:path';
import {createHash} from 'node:crypto';

// Passed directly to Page.evaluate. All DOM helpers must live inside this
// function: the browser callback cannot close over this Node module.
export function inspectLibraryReference() {
  const list = document.querySelector('#record-list');
  const row = list?.querySelector('[data-item="azure"]');
  if (!list || !row) throw new Error('The frozen Azure library state is required');
  const rect = (element) => {
    if (!element) throw new Error('Required reference element missing');
    const r = element.getBoundingClientRect();
    return {x: r.x, y: r.y, width: r.width, height: r.height};
  };
  const css = getComputedStyle(list), box = rect(row);
  const parts = {
    name: row.querySelector('strong'),
    summary: row.querySelector('.item-summary'),
    type: row.querySelector('.item-meta'),
    tag: row.querySelector('.list-tags > span'),
  };
  const fields = {};
  for (const [name, element] of Object.entries(parts)) {
    const b = rect(element), style = getComputedStyle(element);
    // Flutter records the tag Text rectangle, excluding the CSS pill padding.
    if (name === 'tag') {
      const left = parseFloat(style.paddingLeft), top = parseFloat(style.paddingTop);
      b.x += left; b.y += top;
      b.width -= left + parseFloat(style.paddingRight);
      b.height -= top + parseFloat(style.paddingBottom);
    }
    fields[name] = {
      text: element.textContent.trim(),
      rect: b,
      relative: {...b, x: b.x - box.x, y: b.y - box.y},
      fontSize: style.fontSize, lineHeight: style.lineHeight,
    };
  }
  return {
    viewport: {width: innerWidth, height: innerHeight, dpr: devicePixelRatio},
    userAgent: navigator.userAgent,
    fontFamily: getComputedStyle(document.body).fontFamily,
    canvas: getComputedStyle(document.body).getPropertyValue('--canvas').trim(),
    shortcut: document.querySelector('.search kbd')?.textContent.trim(),
    list: {
      rect: rect(list), offsetWidth: list.offsetWidth, clientWidth: list.clientWidth,
      scrollbarWidth: list.offsetWidth - list.clientWidth,
      scrollbarPolicy: css.scrollbarGutter, padding: css.padding,
    },
    row: {id: row.dataset.item, selected: row.classList.contains('selected'), rect: box, fields},
    order: [...list.querySelectorAll('.list-item')].map(r => r.dataset.item),
    query: document.querySelector('#search')?.value,
    filterLabels: {
      type: document.querySelector('button[aria-label="资料类型"]')?.textContent.trim(),
      tag: document.querySelector('button[aria-label="资料标签"]')?.textContent.trim(),
    },
    resultCount: document.querySelector('#result-count')?.textContent,
    groupingAndSort: document.querySelector('#list-order')?.textContent,
  };
}

// Uses the connected Ego Page. It never launches a browser, injects layout CSS,
// hides scrollbars or changes operating-system preferences. A metrics override
// can expire between Ego rounds, so apply and verify it within this same call.
export async function captureLibraryReference(page, {
  width, height, theme, output, expectedGutter = 11, state = 'R01',
}) {
  if (![1440, 1280].includes(width) || height !== (width === 1440 ? 900 : 800) ||
      !['light', 'dark'].includes(theme) || !['R01', 'R02'].includes(state) || !isAbsolute(output)) {
    throw new Error('An explicit supported viewport, theme and absolute output prefix are required');
  }
  await mkdir(dirname(output), {recursive: true});
  await page.cdp('Emulation.setDeviceMetricsOverride', {
    width, height, deviceScaleFactor: 1, mobile: false,
  });
  await page.waitForFunction(() => document.fonts.status === 'loaded' &&
    !document.getAnimations().some(a => a.playState === 'running'));
  const before = await page.evaluate(inspectLibraryReference);
  await page.screenshot({path: `${output}.png`});
  const after = await page.evaluate(inspectLibraryReference);
  const errors = [];
  const expected = {width, height, dpr: 1};
  if (JSON.stringify(before.viewport) !== JSON.stringify(expected) ||
      JSON.stringify(after.viewport) !== JSON.stringify(expected)) errors.push('viewport_changed');
  if (JSON.stringify(before) !== JSON.stringify(after)) errors.push('capture_state_changed');
  if (after.list.scrollbarWidth !== expectedGutter) errors.push('scrollbar_policy_mismatch');
  if (!after.fontFamily.includes('Zhiyu System') || !after.fontFamily.includes('PingFang SC')) errors.push('font_profile_mismatch');
  if (after.shortcut !== '⌘ K') errors.push('shortcut_profile_mismatch');
  if (after.canvas !== (theme === 'dark' ? '#181b22' : '#f1f2f5')) errors.push('theme_mismatch');
  if (!after.row.selected) errors.push('selection_mismatch');
  if (after.query !== (state === 'R01' ? '' : '日本')) errors.push('query_mismatch');
  if (state === 'R02' && after.resultCount !== '1 项') errors.push('result_count_mismatch');
  const labels = state === 'R01' ? {type: '全部类型', tag: '全部标签'} : {type: '服务器信息', tag: '生产环境'};
  if (JSON.stringify(after.filterLabels) !== JSON.stringify(labels)) errors.push('filter_mismatch');
  const report = {
    expected: {viewport: expected, theme, scrollbarWidth: expectedGutter, state},
    before, after, accepted: errors.length === 0, errors,
    imageSha256: createHash('sha256').update(await readFile(`${output}.png`)).digest('hex'),
    overrides: ['installed Mac font families', 'search shortcut marker only'],
    scope: 'Current R01/R02-hit reference capture integrity and measured scrollbar policy; not full S5',
  };
  await writeFile(`${output}.json`, JSON.stringify(report, null, 2) + '\n');
  if (errors.length) throw new Error(`Reference capture rejected: ${errors.join(', ')}`);
  return report;
}
