#!/usr/bin/env python3
"""Serve the frozen prototype with a local-only macOS font profile.

No prototype file or system font is copied or changed. Only manifest-listed
reference files and the system fonts recorded by the Flutter capture are served.
"""
import argparse
import hashlib
import http.server
import json
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[2]
PROTOTYPE = ROOT / 'docs/design/prototypes/round-09-zhiyu'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--fonts', type=Path, required=True)
    parser.add_argument('--port', type=int, default=0)
    args = parser.parse_args()
    profile = json.loads(args.fonts.read_text())
    if profile.get('platform') != 'macos':
        raise ValueError('A captured macOS font profile is required')
    fonts = {name: Path(profile[key]) for name, key in (
        ('system.ttf', 'Zhiyu System'), ('cjk.ttc', 'PingFang SC'))}
    if 'Menlo' in profile:
        fonts['mono.ttc'] = Path(profile['Menlo'])
    for path in fonts.values():
        path.resolve().relative_to('/System/Library')
    manifest = json.loads((PROTOTYPE / 'reference-manifest.json').read_text())
    allowed = {row['file']: row for row in manifest['files']}
    for name, row in allowed.items():
        data = (PROTOTYPE / name).read_bytes()
        if hashlib.sha256(data).hexdigest() != row['sha256']:
            raise ValueError('Frozen prototype changed: ' + name)
    style = '''<style id="mac-platform-fonts">
@font-face {font-family:"Zhiyu System";src:url("/system.ttf");font-weight:100 900;}
@font-face {font-family:"PingFang SC";src:url("/cjk.ttc");font-weight:100 900;}
body {font-family:"Zhiyu System","PingFang SC",sans-serif !important;}
</style>'''
    if 'Menlo' in profile:
        style = style.replace('</style>', '''
@font-face {font-family:"Menlo";src:url("/mono.ttc");}
.mono, pre, code {font-family:"Menlo",monospace !important;}
</style>''')

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            name = urlsplit(self.path).path.lstrip('/') or 'index.html'
            if name in fonts:
                data = fonts[name].read_bytes()
                content_type = 'font/ttf' if name.endswith('.ttf') else 'font/collection'
            elif name in allowed:
                data = (PROTOTYPE / name).read_bytes()
                content_type = {'.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript',
                                '.json': 'application/json'}.get(Path(name).suffix, 'text/plain')
                if name == 'index.html':
                    data = data.decode().replace('</head>', style + '</head>').encode()
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *_):
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    print(json.dumps({'url': f'http://127.0.0.1:{server.server_port}',
                      'override': 'font families only', 'fontFiles': {k: str(v) for k, v in fonts.items()}}), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
