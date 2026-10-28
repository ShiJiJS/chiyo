#!/usr/bin/env python3
"""Compare eligible R05/R06 boxes only after capture/scrollbar guards pass."""
import argparse
import hashlib
import json
from pathlib import Path


def compare(reference, actual):
    cases = []
    for width, height in [(1440, 900), (1280, 800)]:
        for theme in ['light', 'dark']:
            for state in ['R05-top', 'R05-timeline', 'R06-document']:
                name = f'{theme}-{width}-100-{state}'
                ref = json.loads((reference / (name + '.json')).read_text())
                observed = json.loads((actual / (name + '.json')).read_text())
                expected = ref['before']
                errors = []
                if not ref['accepted'] or ref['errors'] or expected != ref['after']:
                    errors.append('reference_capture_integrity')
                image_hash = hashlib.sha256((reference / (name + '.png')).read_bytes()).hexdigest()
                if image_hash != ref['imageSha256']:
                    errors.append('reference_image_hash')
                viewport = {'width': width, 'height': height, 'dpr': 1}
                if expected['viewport'] != viewport or observed['viewport'] != viewport:
                    errors.append('viewport_or_dpr')
                if expected['theme'] != theme or observed['theme'] != theme or observed['textScale'] != 1:
                    errors.append('theme_or_text_scale')
                selection, query = ('https', 'HTTPS') if state == 'R06-document' else ('profile', '\u4e2a\u4eba\u6863\u6848')
                top = 300 if state == 'R05-timeline' else 0
                if expected['selection'] != selection or observed['selection'] != 'information:' + selection:
                    errors.append('selection')
                if expected['query'] != query or observed['query'] != query:
                    errors.append('query')
                if expected['scrollTop'] != top or observed['scrollTop'] != top:
                    errors.append('scroll_position')
                if expected['scrollbarWidth'] != observed['scrollbarWidth']:
                    errors.append('scrollbar_policy')
                keys = [key for key in expected['boxes'] if key != 'document' and not key.endswith('-period')]
                if not keys or any(key not in observed['boxes'] for key in keys):
                    errors.append('required_boxes_missing')
                deltas = {} if errors else {
                    key: {axis: observed['boxes'][key][axis] - value
                          for axis, value in expected['boxes'][key].items()}
                    for key in keys
                }
                maximum = max((abs(v) for box in deltas.values() for v in box.values()), default=None)
                cases.append({'case': name, 'qualified': not errors, 'guardErrors': errors,
                              'referenceScrollbarWidth': expected['scrollbarWidth'],
                              'actualScrollbarWidth': observed['scrollbarWidth'],
                              'eligibleBoxes': len(deltas), 'maximumDelta': maximum,
                              'eligibleGeometryPassed': maximum is not None and maximum <= 2,
                              'deltas': deltas})
    return {
        'thresholdLogicalPixels': 2, 'fullS5Passed': False,
        'scope': 'Normal-size eligible logical boxes; not glyph pixels, full visual, motion or OS input acceptance.',
        'excludedBoxes': {
            'document': 'CSS collapsed margins vs Flutter Column are not the same box; compare headings.',
            '*-period': 'Inline HTML glyph bounds vs SelectableText block are not the same box.',
        },
        'cases': cases,
        'summary': {
            'cases': len(cases), 'qualified': sum(c['qualified'] for c in cases),
            'eligibleGeometryPassed': sum(c['eligibleGeometryPassed'] for c in cases),
            'maximumProfileDelta': max((c['maximumDelta'] for c in cases if 'R05' in c['case'] and c['qualified']), default=None),
            'maximumDocumentDelta': max((c['maximumDelta'] for c in cases if 'R06' in c['case'] and c['qualified']), default=None),
        },
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--actual', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = compare(args.reference, args.actual)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report['summary']))
    return 0 if all(c['eligibleGeometryPassed'] for c in report['cases']) else 1


if __name__ == '__main__':
    raise SystemExit(main())
