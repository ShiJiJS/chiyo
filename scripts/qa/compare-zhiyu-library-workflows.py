#!/usr/bin/env python3
"""Compare frozen Mac workflow geometry without claiming order or full S5 parity."""
import argparse
import json
from pathlib import Path


FIELDS = ('x', 'y', 'width', 'height')


def compare(reference, actual):
    expected = reference['expected']
    target = reference['after']
    if not reference['accepted'] or reference['errors']:
        raise ValueError('Reference capture was rejected')
    if actual['viewport'] != expected['viewport'] or actual['theme'] != expected['theme'] or actual['textScale'] != 1:
        raise ValueError('Viewport, theme and normal text scale must match')
    if actual['state'] != expected['state']:
        raise ValueError('Different workflow state')
    query = actual['query']
    state = target['state']
    if query['directory'] != (None if state['dir'] == 'all' else state['dir']):
        raise ValueError('Different directory scope')
    if query['keyword'] != state['query'] or query['type'] != (None if state['filter'] == 'all' else state['filter']) or query['tagName'] != (state['tag'] or None):
        raise ValueError('Different search/filter conditions')
    if query['grouping'] != {'none': 'none', 'template': 'type', 'directory': 'directory'}[state['groupBy']] or query['sort'] != state['sort']:
        raise ValueError('Different grouping/sort conditions')
    selection = actual['selection']
    if (selection.split(':', 1)[1] if selection else None) != state['selected']:
        raise ValueError('Different selected record')
    if actual['searchFocused'] != target['searchFocused']:
        raise ValueError('Different search focus state')
    if actual['total'] != int(target['resultCount'].split()[0]):
        raise ValueError('Different result count')
    deltas = {}
    keys = set(target['boxes']) & set(actual['boxes'])
    required = {'library-search-frame', 'library-group', 'library-sort', 'library-detail-toolbar', 'library-detail-create'}
    if actual['state'] == 'R02-empty':
        required.update({'library-clear-filters', 'library-results-empty', 'library-detail-empty'})
    if actual['state'].endswith('-menu'):
        required.add('popup')
    if not required <= keys:
        raise ValueError('Required comparable geometry is absent')
    for key in sorted(keys):
        deltas[key] = {field: actual['boxes'][key][field] - target['boxes'][key][field] for field in FIELDS}
    # Group order is a separate unresolved difference. Compare only the same
    # visible leading group, and do not compare an Expanded Text's layout width
    # to a DOM glyph range's ink width or glyph-height rectangle. The count
    # element supplies the common line box; glyph baselines remain unmeasured.
    group_deltas = []
    if actual['groups'] and target['groups']:
        a, r = actual['groups'][0], target['groups'][0]
        if a['label'] == r['label'] and 'labelBox' in r:
            if a['count'] != r['count']:
                raise ValueError('Same group has a different count')
            group_deltas.append({
                'label': a['label'],
                'labelBox': {f: a['labelBox'][f] - r['labelBox'][f] for f in ('x',)},
                'countBox': {f: a['countBox'][f] - r['countBox'][f] for f in FIELDS},
            })
    maximum = max(abs(v) for d in deltas.values() for v in d.values())
    if group_deltas:
        maximum = max(maximum, *(abs(v) for g in group_deltas for k in ('labelBox', 'countBox') for v in g[k].values()))
    order = [key.split(':', 1)[1] for key in actual['order']]
    if actual['state'] == 'R03-name-ungrouped' and order != target['order']:
        raise ValueError('Ungrouped name order differs from the same frozen records')
    return {'state': actual['state'], 'viewport': actual['viewport'], 'theme': actual['theme'],
            'deltas': deltas, 'sameLeadingGroupDeltas': group_deltas,
            'maximumGeometryDelta': maximum, 'geometryWithin2px': maximum <= 2,
            'orderEqual': order == target['order'],
            'actualOrder': order, 'referenceOrder': target['order'],
            'scope': 'Shared measured boxes only; grouped/name ordering, normal-speed motion and OS input remain separate',
            'fullS5Passed': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, action='append', required=True,
                        help='Reference directories in precedence order; later captures override earlier files')
    parser.add_argument('--actual', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--case-count', type=int, default=40)
    args = parser.parse_args()
    cases = {}
    references = {}
    for directory in args.reference:
        for path in sorted(directory.glob('*.json')):
            references[path.name] = path
    for path in references.values():
        cases[path.stem] = compare(json.loads(path.read_text()), json.loads((args.actual / path.name).read_text()))
        cases[path.stem]['referencePath'] = str(path)
    if len(cases) != args.case_count:
        raise ValueError('Workflow case count differs from the explicit capture matrix')
    report = {'cases': cases, 'caseCount': len(cases),
              'maximumGeometryDelta': max(case['maximumGeometryDelta'] for case in cases.values()),
              'allMeasuredGeometryWithin2px': all(case['geometryWithin2px'] for case in cases.values()),
              'fullS5Passed': False}
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k != 'cases'}))
    if not report['allMeasuredGeometryWithin2px']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
