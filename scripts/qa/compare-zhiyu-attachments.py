#!/usr/bin/env python3
"""Guarded chrome comparison; real file pixels and required controls stay explicit."""
import argparse
import hashlib
import json
from pathlib import Path


def compare(reference, actual):
    cases = []
    for width, height in [(1440, 900), (1280, 800)]:
        for theme in ['light', 'dark']:
            for state, query in [('resume', '\u670d\u52a1\u7aef\u5f00\u53d1\u7b80\u5386'), ('sshkey', 'Azure SSH')]:
                name = f'{theme}-{width}-100-{state}'
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
                expected_selection = ('information:' if state == 'resume' else 'credential:') + state
                if r['selection'] != state or a['selection'] != expected_selection or r['query'] != query or a['query'] != query:
                    errors.append('identity_or_query')
                if r['scrollTop'] != 0 or a['scrollTop'] != 0 or r['scrollbarWidth'] != a['scrollbarWidth']:
                    errors.append('scroll_condition')
                required = {'detail-title', 'file-stage'} if state == 'resume' else {'detail-title', 'credential-summary', 'credential-icon', 'credential-status', 'credential-format'}
                if not required.issubset(a['boxes']) or not required.issubset(r['boxes']):
                    errors.append('required_boxes')
                deltas = {} if errors else {key: {axis: a['boxes'][key][axis] - value for axis, value in r['boxes'][key].items()} for key in required}
                maximum = None
                if state == 'sshkey' and not errors:
                    maximum = max(abs(value) for key, box in deltas.items() if key != 'credential-format' for value in box.values())
                cases.append({'case': name, 'qualifiedCaptureConditions': not errors, 'guardErrors': errors,
                              'credentialOuterMaximumDelta': maximum,
                              'credentialOuterGeometryPassed': maximum is not None and maximum <= 2,
                              'fileFrameWidthPassed': state == 'resume' and not errors and all(abs(deltas['file-stage'][axis]) <= 2 for axis in ['x', 'width']),
                              'fileToolbarTopDelta': deltas.get('file-stage', {}).get('y'),
                              'fullS5Passed': False, 'deltas': deltas})
    return {'cases': cases, 'thresholdLogicalPixels': 2, 'fullS5Passed': False,
            'limits': ['File uses real bundled bytes; HTML fictional paper and natural page height are not pixel references.',
                       'File toolbar top remains an explicit difference while page/zoom/save/replace/metadata controls are preserved.',
                       'Credential format includes material version; format boxes are diagnostic, not identical-text glyph acceptance.',
                       'Credential actions/sections, full text baselines, normal-speed motion and OS input still require checks.'],
            'summary': {'qualifiedCases': sum(c['qualifiedCaptureConditions'] for c in cases),
                        'credentialOuterCasesPassed': sum(c['credentialOuterGeometryPassed'] for c in cases),
                        'fileFrameWidthsPassed': sum(c['fileFrameWidthPassed'] for c in cases),
                        'maximumCredentialOuterDelta': max((c['credentialOuterMaximumDelta'] for c in cases if c['credentialOuterMaximumDelta'] is not None), default=None),
                        'maximumFileToolbarTopDelta': max((abs(c['fileToolbarTopDelta']) for c in cases if c['fileToolbarTopDelta'] is not None), default=None)}}


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
    return 0 if all(c['qualifiedCaptureConditions'] and (c['credentialOuterGeometryPassed'] if 'sshkey' in c['case'] else c['fileFrameWidthPassed'] and abs(c['fileToolbarTopDelta']) <= 2) for c in report['cases']) else 1


if __name__ == '__main__':
    raise SystemExit(main())
