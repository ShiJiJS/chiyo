#!/usr/bin/env python3
"""Compare measured R01/R02-hit row geometry without hiding viewport/order differences."""
import argparse
import json
from pathlib import Path


def compare(reference, actual, state, width, height, theme, reference_state):
    expected_viewport = {'width': width, 'height': height, 'dpr': 1}
    if not reference['accepted'] or reference['errors']:
        raise ValueError('A rejected reference cannot be used as a baseline')
    if reference['after']['viewport'] != expected_viewport or state['viewport'] != expected_viewport:
        raise ValueError('Reference and actual must use the same measured viewport')
    if state['theme'] != theme or state['textScale'] != 1:
        raise ValueError('Reference and actual must use the same theme and text scale')
    if state['selection'] != 'information:azure' or reference['after']['row']['id'] != 'azure':
        raise ValueError('The same typed Azure record must be selected')
    if state['filterLabels'] != reference['after']['filterLabels'] or state['query']['keyword'] != reference['after']['query']:
        raise ValueError('Query and filter labels must match the recorded reference state')
    ref = reference['after']['row']
    row = actual['library-record-information:azure']
    deltas = {k: row[k] - ref['rect'][k] for k in ['x', 'width', 'height']}
    if reference_state == 'R02':
        if state['query']['keyword'] != '日本' or state['total'] != 1:
            raise ValueError('R02 requires the explicit one-result Japanese server intersection')
        deltas['y'] = row['y'] - ref['rect']['y']
    fields = {}
    for name in ['name', 'summary', 'type', 'tag']:
        observed = actual['row-' + name]
        target = ref['fields'][name]
        if state['selectedRowText'][name] != target['text']:
            raise ValueError('Different source text cannot prove matching line layout: ' + name)
        relative = {**observed, 'x': observed['x'] - row['x'], 'y': observed['y'] - row['y']}
        fields[name] = {k: relative[k] - target['relative'][k] for k in ['x', 'y', 'width', 'height']}
    max_delta = max(abs(v) for v in deltas.values())
    max_delta = max(max_delta, *(abs(v) for field in fields.values() for v in field.values()))
    if state['rowPaneRightGap'] < reference['after']['list']['scrollbarWidth']:
        raise ValueError('The row extends into the measured scrollbar lane')
    summary_height = ref['fields']['summary']['rect']['height']
    line_height = float(ref['fields']['summary']['lineHeight'].removesuffix('px'))
    report = {
        'viewport': expected_viewport, 'theme': theme, 'referenceState': reference_state,
        'referenceScrollbarWidth': reference['after']['list']['scrollbarWidth'],
        'actualRowPaneRightGap': state['rowPaneRightGap'],
        'rowDelta': deltas, 'fieldRelativeDelta': fields, 'maxCoveredDelta': max_delta,
        'referenceSummaryLines': round(summary_height / line_height),
        'actualSummaryHeight': actual['row-summary']['height'],
        'absoluteRowTopDelta': row['y'] - ref['rect']['y'],
        'referenceOrder': reference['after']['order'], 'actualTypedOrder': state['order'],
        'coveredSubsetPassed': max_delta <= 2,
        'scope': 'Row geometry and same-text relative fields; R02 includes absolute y; R01 retains ordering difference; excludes other page regions',
        'fullS5Passed': False,
    }
    if not report['coveredSubsetPassed']:
        raise ValueError('Covered row geometry exceeds the unchanged 2px S5 target: ' + str(max_delta))
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--actual', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--details', action='store_true',
                        help='Also compare the recorded R01/R02 Azure header, sidebar tags and relation boxes')
    parser.add_argument('--title-reference', type=Path,
                        help='Optional measured same-font CSS title advance profile')
    args = parser.parse_args()
    reports = {}
    for width, height in [(1440, 900), (1280, 800)]:
        for theme in ['light', 'dark']:
            for reference_state in ['R01', 'R02']:
                name = f'{theme}-{width}'
                actual_name = name if reference_state == 'R01' else name + '-R02'
                load = lambda path: json.loads(path.read_text())
                reference = load(args.reference / f'{name}-{reference_state}.json')
                actual = load(args.actual / f'{actual_name}-library-geometry.json')
                state = load(args.actual / f'{actual_name}-library-state.json')
                report = compare(
                    reference, actual,
                    state,
                    width, height, theme, reference_state)
                if args.details:
                    keys = {
                        'title': 'library-detail-title',
                        'description': 'library-detail-description',
                        'meta': 'library-detail-meta', 'type': 'library-detail-type',
                        'japanTag': 'library-detail-tag-tag-0',
                        'editTags': 'library-detail-edit-tags',
                        'sideTagLabel': 'library-tag-label',
                        'sideTagManage': 'library-tags-manage', 'cloud': 'library-tag-cloud',
                        'credential': 'library-relation-credential:sshkey',
                        'https': 'library-relation-information:https',
                        'sshguide': 'library-relation-information:sshguide',
                    }
                    boxes = reference['after']['detailBoxes']
                    deltas = {key: {axis: actual[target][axis] - boxes[key][axis]
                                    for axis in ['x', 'y', 'width', 'height']}
                              for key, target in keys.items()}
                    maximum = max(abs(v) for box in deltas.values() for v in box.values())
                    if maximum > 2:
                        raise ValueError(f'{name}-{reference_state} detail boxes exceed 2px: {deltas}')
                    report['detailBoxDeltas'] = deltas
                    report['detailMaxDelta'] = maximum
                    report['detailScope'] = 'Recorded Azure header, sidebar tag region and three relation boxes only; excludes motion, other records and actual OS input'
                if args.title_reference:
                    title = load(args.title_reference)[str(width)]
                    if title['viewport'] != state['viewport'] or title['text'] != state['selectedRowText']['name']:
                        raise ValueError('Title advance profile viewport/text does not match actual')
                    delta = actual['library-detail-title-advance'] - title['advance']
                    if abs(delta) > 2:
                        raise ValueError(f'{name}-{reference_state} title advance exceeds 2px: {delta}')
                    report['titleAdvanceDelta'] = delta
                    report['titleAdvanceScope'] = 'Same-font CSS Range/Flutter fallback-run union widths; theme-independent font metrics, not glyph baseline/pixel equality'
                reports[f'{name}-{reference_state}'] = report
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(reports, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({name: {'maxCoveredDelta': r['maxCoveredDelta'],
                             'absoluteRowTopDelta': r['absoluteRowTopDelta'],
                             'fullS5Passed': r['fullS5Passed']} for name, r in reports.items()}))


if __name__ == '__main__':
    main()
