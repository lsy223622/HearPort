"""Compare complete receiver revisions under identical synthetic playback inputs."""
import json
import sys
from pathlib import Path

CONFIGURATION = ('scenario', 'content', 'adaptive', 'seed', 'callbackFrames',
                 'uncertaintyMilliseconds', 'targetMilliseconds', 'maximumMilliseconds',
                 'outputClockPPM', 'pumpJitterMilliseconds', 'callbackPhaseMicroseconds')


def compare(root, unchanged=False):
    revisions = {}
    for reference in ('943523a', '49b8ee5', 'working'):
        path = root / f'HearPort-offline-playback-{reference}' / 'playback.json'
        rows = json.loads(path.read_text(encoding='utf-8'))
        indexed = {tuple(row[key] for key in CONFIGURATION): row for row in rows}
        assert len(indexed) == len(rows), f'duplicate cases: {reference}'
        revisions[reference] = indexed
    current = revisions['working']
    assert all(rows.keys() == current.keys() for rows in revisions.values()), 'case matrices differ'
    results = []
    failures = []
    for key, row in current.items():
        versions = {reference: rows[key] for reference, rows in revisions.items()}
        assert len({value['inputFingerprint'] for value in versions.values()}) == 1, f'packet inputs differ: {key}'
        baseline = versions['49b8ee5']
        if unchanged:
            strip = lambda value: {k: v for k, v in value.items() if k != 'implementation'}
            assert strip(row) == strip(baseline), f'unchanged production replay differs: {key}'
        metrics = {}
        for reference, value in versions.items():
            unavailable = value['sourceCursor'] - value['originalSourceSpan']
            assert unavailable >= 0, f'original source coverage exceeds consumed cursor: {key}'
            accounted = value['originalSourceSpan'] + value['concealedSourceSpan'] + value['expiredSourceSpan']
            assert accounted <= value['sourceCursor'], f'source spans overlap: {key}'
            metrics[reference] = {
                'unavailableSourceMilliseconds': unavailable / 48,
                'underflowMilliseconds': value['underflowAfterStartFrames'] / 48,
                'concealedPreparedMilliseconds': value['concealedPreparedFrames'] / 48,
                'longestNearSilenceMilliseconds': value['longestNearSilenceMilliseconds'],
                'maximumSourceAgeBoundMilliseconds': value['maximumSourceAgeBoundMilliseconds'],
                'recovery': value['recovery'],
            }
        if metrics['working']['unavailableSourceMilliseconds'] > metrics['49b8ee5']['unavailableSourceMilliseconds'] + 2.5:
            failures.append({'configuration': dict(zip(CONFIGURATION, key)), 'reason': 'additional unavailable source exceeds one packet'})
        if row['longestNearSilenceMilliseconds'] > baseline['longestNearSilenceMilliseconds'] + row['callbackFrames'] / 48:
            failures.append({'configuration': dict(zip(CONFIGURATION, key)), 'reason': 'additional near-silence exceeds one callback'})
        results.append({'configuration': dict(zip(CONFIGURATION, key)), 'inputFingerprint': row['inputFingerprint'], 'metrics': metrics})
    return {'casesPerRevision': len(current), 'identicalPacketInputs': True,
            'unchangedProductionControl': unchanged, 'failures': failures, 'cases': results}


if __name__ == '__main__':
    root = Path(sys.argv[1])
    result = compare(root, '--unchanged' in sys.argv[2:])
    (root / 'comparison.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(f"paired_playback_cases={result['casesPerRevision']} regression_failures={len(result['failures'])}")
    if result['failures']:
        raise SystemExit(1)
