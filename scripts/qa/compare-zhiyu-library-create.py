#!/usr/bin/env python3
"""Compare settled chooser frames without claiming full S5 acceptance."""
import argparse
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--reference', type=Path, required=True)
parser.add_argument('--actual', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
results = []
for width, height in [(1440, 900), (1280, 800)]:
    for theme in ['light', 'dark']:
        name = f'{theme}-{width}-100-chooser'
        ref = json.loads((args.reference / f'{name}.json').read_text())
        actual = json.loads((args.actual / f'{name}.json').read_text())
        assert ref['accepted'] and ref['after']['theme'] == theme
        assert ref['after']['viewport'] == {'width': width, 'height': height, 'dpr': 1}
        assert actual['viewport'] == {'width': width, 'height': height}
        assert actual['theme'] == theme and actual['textScale'] == 1
        image = args.reference / f'{name}.png'
        assert hashlib.sha256(image.read_bytes()).hexdigest() == ref['imageSha256']
        deltas = {key: {axis: abs(actual['boxes'][key][axis] - value)
                        for axis, value in box.items()}
                  for key, box in ref['after']['boxes'].items()}
        maximum = max(v for box in deltas.values() for v in box.values())
        results.append({'case': name, 'maximumDelta': maximum, 'deltas': deltas,
                        'actualImageSha256': hashlib.sha256((args.actual / f'{name}.png').read_bytes()).hexdigest(),
                        'accepted': maximum <= 2})
report = {'cases': results, 'accepted': all(r['accepted'] for r in results),
          'threshold': 2, 'fullS5Passed': False,
          'scope': 'Normal-size chooser geometry only; 200% covered by Widget navigation checks.'}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({'accepted': report['accepted'], 'cases': len(results),
                  'maximumDelta': max(r['maximumDelta'] for r in results)}))
raise SystemExit(0 if report['accepted'] else 1)
