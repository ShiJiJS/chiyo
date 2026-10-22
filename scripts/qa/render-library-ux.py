"""Render current Flutter pages without overwriting archived design evidence.

Run from any directory with --flutter-bin <Flutter bin directory>. Uses existing
fake-data capture scenarios, copied under the desktop package's ignored cache.
No dependency resolution, real profile, browser or existing app is involved.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--flutter-bin', required=True)
parser.add_argument('--pages', nargs='+', default=['library', 'workspace', 'credentials', 'credential_use', 'proposals', 'history_settings'])
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
app = root / 'apps/desktop'
cache = app / '.dart_tool/library-ux'
cache.mkdir(parents=True, exist_ok=True)
evidence = root / 'build/library-ux'
evidence.mkdir(parents=True, exist_ok=True)
results = []
for page in args.pages:
    if not re.fullmatch(r'[a-z_]+', page):
        raise ValueError('Invalid capture name')
    source = app / 'tool' / f'capture_{page}.dart'
    text = source.read_text(encoding='utf-8')
    text = re.sub(r'\.\./\.\./docs/development/evidence/[^/\x27]+', f'../../build/library-ux/flutter/{page}', text)
    for path in re.findall(r"'((?:\.\./){2}build/library-ux/[^']+)'", text):
        fixed = path.split('$', 1)[0]
        directory = (app / fixed).resolve()
        if '$' in path and not fixed.endswith('/') or directory.suffix:
            directory = directory.parent
        if not directory.is_relative_to(evidence.resolve()):
            raise ValueError('Capture path escaped the evidence directory')
        directory.mkdir(parents=True, exist_ok=True)
    if 'MaterialApp(' in text and 'scrollBehavior:' not in text:
        text = "import 'package:info_desktop/desktop_scroll.dart';\n" + text
        text = text.replace('MaterialApp(', 'MaterialApp(scrollBehavior: const DesktopScrollBehavior(),')
    target = cache / source.name
    target.write_text(text, encoding='utf-8')
    command = [str(Path(args.flutter_bin) / ('flutter.bat' if os.name == 'nt' else 'flutter')), 'test', '--no-pub', str(target), '--reporter', 'expanded']
    log_path = evidence / f'render-{page}.log'
    with log_path.open('w', encoding='utf-8') as log:
        run = subprocess.run(command, cwd=app, stdout=log, stderr=subprocess.STDOUT)
    results.append({'page': page, 'exitCode': run.returncode, 'log': str(log_path.relative_to(root))})
    print(f'{page}: {run.returncode}', flush=True)
    (evidence / 'render-results.json').write_text(json.dumps(results, indent=2), encoding='utf-8')
    if run.returncode:
        print('\n'.join(log_path.read_text(encoding='utf-8', errors='replace').splitlines()[-18:]))
        raise SystemExit(run.returncode)
