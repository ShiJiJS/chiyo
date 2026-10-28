#!/usr/bin/env python3
"""Compare shared single-line control metrics across distinct Owner forms."""
import argparse
import hashlib
import json
from pathlib import Path


def compare(reference, actual):
    cases = []
    for width, height in [(1440, 900), (1280, 800)]:
        for theme in ['light', 'dark']:
            ref = json.loads((reference / f'{theme}-{width}.json').read_text())
            r = ref['before']
            for replace in [False, True]:
                name = f'field-{theme}-{width}-100-replace-{str(replace).lower()}'
                a = json.loads((actual / f'{name}.json').read_text())
                errors = []
                if not ref['accepted'] or r != ref['after'] or hashlib.sha256((reference / f'{theme}-{width}.png').read_bytes()).hexdigest() != ref['imageSha256']:
                    errors.append('reference_integrity')
                viewport = {'width': width, 'height': height, 'dpr': 1}
                if r['viewport'] != viewport or a['viewport'] != viewport:
                    errors.append('viewport_or_dpr')
                if r['theme'] != theme or a['theme'] != theme or a['textScale'] != 1:
                    errors.append('theme_or_text_scale')
                if r['selection'] != 'sshkey' or r['query'] != 'Azure SSH' or r['kind'] != 'credential' or a['replace'] != replace:
                    errors.append('form_context')
                required = {'labelHeight', 'gap', 'inputHeight', 'labelFontSize', 'labelWeight'}
                if any(k not in a['fields'] or not required.issubset(a['fields'][k]) or k not in r['fields'] or not required.issubset(r['fields'][k]) for k in ['name', 'binding']) or 'nextFieldGap' not in a['fields'].get('name', {}) or 'nextFieldGap' not in r['fields'].get('name', {}):
                    errors.append('required_field_metrics')
                if not errors and any(a['fields'][k][p] != r['fields'][k][p] for k in ['name', 'binding'] for p in ['labelFontSize', 'labelWeight']):
                    errors.append('label_typography')
                deltas = {} if errors else {k: {p: a['fields'][k][p] - value for p, value in r['fields'][k].items() if p not in ['labelFontSize', 'labelWeight']} for k in ['name', 'binding']}
                maximum = max((abs(v) for d in deltas.values() for v in d.values()), default=None)
                cases.append({'case': name, 'qualifiedConditions': not errors, 'guardErrors': errors,
                              'maximumControlMetricDelta': maximum, 'commonControlMetricsPassed': maximum is not None and maximum <= 2,
                              'wholeFormPassed': False, 'fullS5Passed': False, 'deltas': deltas})
    return {'cases': cases, 'thresholdLogicalPixels': 2, 'wholeFormPassed': False, 'fullS5Passed': False,
            'scope': 'Common single-line label size/weight/height, label-input gap, input outer height, and name-to-next-field gap only.',
            'limits': ['Source core form and actual secure-picker Owner forms have different text, fields and actions; not whole-form pixel identity.',
                       '200% actual layouts are tested separately, not treated as CSS browser zoom equivalence.',
                       'Complete form geometry, glyph baselines, shadows, motion and physical OS input remain open.'],
            'summary': {'qualifiedCases': sum(c['qualifiedConditions'] for c in cases),
                        'commonControlCasesPassed': sum(c['commonControlMetricsPassed'] for c in cases),
                        'maximumControlMetricDelta': max((c['maximumControlMetricDelta'] for c in cases if c['maximumControlMetricDelta'] is not None), default=None)}}


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
    return 0 if all(c['commonControlMetricsPassed'] for c in report['cases']) else 1


if __name__ == '__main__':
    raise SystemExit(main())
