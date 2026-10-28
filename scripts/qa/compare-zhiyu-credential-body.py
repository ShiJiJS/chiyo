#!/usr/bin/env python3
"""Compare complete supported-SSH reading blocks, not inline glyph boxes."""
import argparse
import hashlib
import json
from pathlib import Path


KEYS = [
    'credential-section-purpose-title', 'credential-purpose',
    'credential-section-use-title', 'credential-delivery-fact', 'credential-delivery-label',
    'credential-binding-fact', 'credential-binding-label', 'credential-use-note',
    'credential-section-relations-title',
    'library-relation-frame-information:azure', 'library-relation-icon-information:azure',
    'library-relation-text-information:azure', 'library-relation-description-information:azure',
    'library-relation-chevron-information:azure',
]


def compare(reference, actual):
    cases = []
    for width, height in [(1440, 900), (1280, 800)]:
        for theme in ['light', 'dark']:
            name = f'{theme}-{width}-100-sshkey'
            ref = json.loads((reference / (name + '.json')).read_text())
            a = json.loads((actual / (name + '.json')).read_text())
            r = ref['before']
            errors = []
            if not ref['accepted'] or r != ref['after'] or hashlib.sha256((reference / (name + '.png')).read_bytes()).hexdigest() != ref['imageSha256']:
                errors.append('reference_integrity')
            viewport = {'width': width, 'height': height, 'dpr': 1}
            if r['viewport'] != viewport or a['viewport'] != viewport:
                errors.append('viewport_or_dpr')
            if r['theme'] != theme or a['theme'] != theme or a['textScale'] != 1:
                errors.append('theme_or_text_scale')
            if r['selection'] != 'sshkey' or a['selection'] != 'credential:sshkey' or r['query'] != 'Azure SSH' or a['query'] != 'Azure SSH':
                errors.append('identity_or_query')
            if r['scrollTop'] != 0 or a['scrollTop'] != 0 or r['scrollbarWidth'] != a['scrollbarWidth']:
                errors.append('scroll_condition')
            if not set(KEYS).issubset(a['boxes']) or not set(KEYS).issubset(r['boxes']):
                errors.append('required_body_boxes')
            if not r.get('credentialReading') or r.get('credentialReading') != a.get('credentialReading'):
                errors.append('displayed_reading_content')
            deltas = {} if errors else {key: {axis: a['boxes'][key][axis] - value for axis, value in r['boxes'][key].items()} for key in KEYS}
            maximum = max((abs(v) for b in deltas.values() for v in b.values()), default=None)
            cases.append({'case': name, 'qualifiedCaptureConditions': not errors, 'guardErrors': errors,
                          'maximumBodyBlockDelta': maximum, 'bodyBlockGeometryPassed': maximum is not None and maximum <= 2,
                          'fullS5Passed': False, 'deltas': deltas})
    return {'cases': cases, 'thresholdLogicalPixels': 2, 'fullS5Passed': False,
            'scope': 'Supported SSH purpose/use facts/note/relation blocks. Inline strong glyph rectangles are not compared with whole Flutter line boxes.',
            'limits': ['Summary format now also shows a fixed mask and material version; not identical-text acceptance.',
                       'Owner private notes and additional actions are retained outside the frozen basic reading blocks.',
                       'Storage-only/focus/disabled/error flows have separate functional checks; this matrix does not accept their full visual geometry.',
                       'Full glyph baselines, shadows, normal-speed motion and physical OS input remain open.'],
            'summary': {'qualifiedCases': sum(c['qualifiedCaptureConditions'] for c in cases),
                        'bodyBlockCasesPassed': sum(c['bodyBlockGeometryPassed'] for c in cases),
                        'measuredBlocksPerCase': len(KEYS),
                        'maximumBodyBlockDelta': max((c['maximumBodyBlockDelta'] for c in cases if c['maximumBodyBlockDelta'] is not None), default=None)}}


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
    return 0 if all(c['bodyBlockGeometryPassed'] for c in report['cases']) else 1


if __name__ == '__main__':
    raise SystemExit(main())
