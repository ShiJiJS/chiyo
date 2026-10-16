"""Read-only snapshot of native GitHub dependencies for the design audit."""
import concurrent.futures
import json
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parent

def read(number):
    result = subprocess.run(['gh', 'api', f'repos/ShiJiJS/agent-info-manage/issues/{number}/dependencies/blocked_by'], check=True, capture_output=True, text=True, encoding='utf-8')
    return {'number': number, 'blockedBy': [i['number'] for i in json.loads(result.stdout)]}

with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    rows = list(pool.map(read, range(2, 20)))
(root / 'dependencies.json').write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps(rows, ensure_ascii=False))
