import { readFile, writeFile } from 'node:fs/promises';

const source = await readFile('C:/Project/network_config/info-manage-worktrees/23-prototype-icons/docs/design/prototypes/round-05/index.html', 'utf8');
const symbols = source.match(/<svg class="symbols"[\s\S]*?<\/svg>/)[0];
const names = [...symbols.matchAll(/<symbol id="([^"]+)"/g)].map(match => match[1]);
const rows = [18, 26, 72].map(size => `<div class="row">${names.map(name => `<div class="cell"><svg width="${size}" height="${size}"><use href="#${name}"/></svg></div>`).join('')}</div>`).join('');
await writeFile(new URL('source-icons.html', import.meta.url), `<!doctype html><meta charset="utf-8"><style>body{margin:0;width:1248px;height:288px;background:#fff;overflow:hidden}.symbols{position:absolute;width:0;height:0;overflow:hidden}svg{fill:none;stroke:#000;stroke-width:1.65;stroke-linecap:round;stroke-linejoin:round;flex:none}.row{display:flex;height:96px}.cell{width:96px;height:96px;display:grid;place-items:center}</style>${symbols}${rows}`);
console.log({ names, sizes: [18, 26, 72] });
