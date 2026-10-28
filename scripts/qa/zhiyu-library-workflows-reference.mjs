import {mkdir, readFile, writeFile} from 'node:fs/promises';
import {dirname, isAbsolute} from 'node:path';
import {createHash} from 'node:crypto';

export function inspectLibraryWorkflow() {
  const rect = e => {
    const r = e.getBoundingClientRect();
    return {x: r.x, y: r.y, width: r.width, height: r.height};
  };
  const boxes = {};
  for (const [name, selector] of Object.entries({
    'library-search-frame': '.browse-header .search',
    'library-group': 'button[data-xmenu="group"]',
    'library-sort': 'button[data-xmenu="sort"]',
    'library-results-pane': '.browse-pane',
    'library-results-footer': '.browse-footer',
    'library-detail-toolbar': '.detail-toolbar',
    'library-detail-create': '.detail-toolbar button[data-action="new"]',
    'library-clear-filters': '#record-list [data-action="clear"]',
    'library-detail-title': '.detail-header h1',
    'library-results-empty': '#record-list .empty',
    'library-results-empty-title': '#record-list .empty h2',
    'library-results-empty-description': '#record-list .empty p',
    'library-detail-empty': '#record-detail .empty',
    'library-detail-empty-title': '#record-detail .empty h2',
    'library-detail-empty-description': '#record-detail .empty p',
    popup: '#menu-root .floating-menu',
    'library-relation-frame-information:https': '#record-detail .relation[data-item="https"]',
    'library-relation-frame-information:sshguide': '#record-detail .relation[data-item="sshguide"]',
    'library-relation-frame-credential:sshkey': '#record-detail .relation[data-item="sshkey"]',
  })) {
    const e = document.querySelector(selector);
    if (e) boxes[name] = rect(e);
  }
  for (const [key, name] of Object.entries({url: '访问入口', purpose: '应用用途', auth: '认证方式'})) {
    const label = [...document.querySelectorAll('#record-detail .fact label')].find(e => e.textContent.trim() === name);
    if (label) {
      boxes[`library-field-${key}-label`] = rect(label);
      boxes[`library-field-${key}-value`] = rect(label.nextElementSibling);
    }
  }
  const raw = window.ROUND9?.state;
  if (!raw) throw new Error('Frozen reference is not initialized');
  const state = Object.fromEntries([
    'page', 'dir', 'selected', 'query', 'filter', 'tag', 'groupBy', 'sort',
    'detailTab', 'setting', 'plugin', 'pluginTab',
  ].map(k => [k, raw[k] ?? null]));
  const list = document.querySelector('#record-list');
  const search = document.querySelector('#search');
  const frame = search?.closest('.search');
  const frameStyle = frame && getComputedStyle(frame);
  return {
    viewport: {width: innerWidth, height: innerHeight, dpr: devicePixelRatio},
    fontFamily: getComputedStyle(document.body).fontFamily,
    canvas: getComputedStyle(document.body).getPropertyValue('--canvas').trim(),
    state, boxes, searchFocused: !!search && document.activeElement === search,
    searchAppearance: frameStyle && {borderColor: frameStyle.borderColor, boxShadow: frameStyle.boxShadow},
    scrollbarWidth: list ? list.offsetWidth - list.clientWidth : null,
    resultCount: document.querySelector('#result-count')?.textContent,
    order: list ? [...list.querySelectorAll('.list-item')].map(e => e.dataset.item) : [],
    groups: list ? [...list.querySelectorAll('.list-group')].map(e => {
      const range = document.createRange();
      range.selectNode(e.firstChild);
      return {label: e.firstChild.textContent, count: e.querySelector('span')?.textContent,
        box: rect(e), labelBox: rect(range), countBox: rect(e.querySelector('span'))};
    }) : [],
    detailTitle: document.querySelector('.detail-header h1')?.textContent,
    popupLabels: [...document.querySelectorAll('#menu-root [role="menuitemradio"]')].map(e => e.textContent.trim()),
  };
}

// prepare runs after the same-call viewport override. Opening a menu before
// that override can close it on resize; never treat that as a captured menu.
export async function captureLibraryWorkflow(page, {
  width, height, theme, state, output, expected, requiredBoxes = [], prepare,
  expectedGutter = 11,
}) {
  if (![1440, 1280].includes(width) || height !== (width === 1440 ? 900 : 800) ||
      !['light', 'dark'].includes(theme) || !isAbsolute(output) || !expected || !state) {
    throw new Error('Explicit workflow capture conditions are required');
  }
  await mkdir(dirname(output), {recursive: true});
  await page.cdp('Emulation.setDeviceMetricsOverride', {width, height, deviceScaleFactor: 1, mobile: false});
  if (prepare) await prepare(page);
  await page.waitForSelector('#toast-root .toast', {state: 'hidden'});
  await page.waitForFunction(() => document.fonts.status === 'loaded' && !document.getAnimations().some(a => a.playState === 'running'));
  const before = await page.evaluate(inspectLibraryWorkflow);
  await page.screenshot({path: output + '.png'});
  const after = await page.evaluate(inspectLibraryWorkflow);
  const errors = [];
  if (JSON.stringify(before) !== JSON.stringify(after)) errors.push('capture_state_changed');
  if (JSON.stringify(after.viewport) !== JSON.stringify({width, height, dpr: 1})) errors.push('viewport_mismatch');
  if (!after.fontFamily.includes('Zhiyu System') || !after.fontFamily.includes('PingFang SC')) errors.push('font_profile_mismatch');
  if (after.canvas !== (theme === 'dark' ? '#181b22' : '#f1f2f5')) errors.push('theme_mismatch');
  if (after.scrollbarWidth !== null && after.scrollbarWidth !== expectedGutter) errors.push('scrollbar_policy_mismatch');
  for (const [key, value] of Object.entries(expected)) {
    if (after.state[key] !== value) errors.push('state_' + key);
  }
  for (const key of requiredBoxes) if (!after.boxes[key]) errors.push('missing_' + key);
  const report = {expected: {viewport: {width, height, dpr: 1}, theme, state, stateFields: expected, requiredBoxes, scrollbarWidth: expectedGutter},
    before, after, errors, accepted: !errors.length,
    imageSha256: createHash('sha256').update(await readFile(output + '.png')).digest('hex'),
    scope: 'Frozen Mac workflow capture integrity; not full S5 or actual OS input', fullS5Passed: false};
  await writeFile(output + '.json', JSON.stringify(report, null, 2) + '\n');
  if (errors.length) throw new Error('Workflow reference rejected: ' + errors.join(', '));
  return report;
}
