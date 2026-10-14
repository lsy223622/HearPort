"""Summarize deterministic, paired controller experiments."""

import argparse
import csv
import json
import random
from collections import defaultdict
from pathlib import Path
from statistics import mean


def paired_differences(rows):
    grouped = defaultdict(dict)
    for row in rows:
        key = (row['scenario'], row['transport'], row['targetMilliseconds'],
               row['maximumMilliseconds'], row['seed'])
        grouped[key][row['policy']] = row
    differences = defaultdict(list)
    for key, policies in grouped.items():
        if 'fixed' not in policies:
            raise ValueError('paired experiment has no fixed control')
        control = policies['fixed']
        for policy, row in policies.items():
            if row['inputFingerprint'] != control['inputFingerprint']:
                raise ValueError('paired policies used different network inputs')
            if policy != 'fixed':
                differences[key[:-1] + (policy,)].append(
                    row['unavailableSourcePercent'] - control['unavailableSourcePercent'])
    return differences


def interval(values):
    rng = random.Random(20261015)
    bootstraps = sorted(mean(rng.choices(values, k=len(values))) for _ in range(2000))
    return bootstraps[49], bootstraps[1949]


def write_report(directory):
    rows = json.loads((directory / 'playout.json').read_text(encoding='utf-8'))
    recovery = json.loads((directory / 'recovery.json').read_text(encoding='utf-8'))['rows']
    differences = paired_differences(rows)
    aggregate = defaultdict(list)
    for row in rows:
        key = (row['scenario'], row['transport'], row['targetMilliseconds'],
               row['maximumMilliseconds'], row['policy'])
        aggregate[key].append(row)
    lines = ['# Offline transport experiment', '',
        f'{len(rows)} cases; each case has 30 seconds of virtual source audio. '
        'All policies share an identical input fingerprint within each scenario and seed.', '',
        '## Model boundaries', '',
        '- Executes the production Swift PlayoutController and ProbeConsumer.',
        '- Datagram delivers surviving packets independently. The reliable model assumes '
        'one successful retry per lost packet and ordered delivery with head-of-line blocking.',
        '- The reliable playout model has no stream restart, congestion control, or real MsQuic engine. '
        'Recovery decisions are audited separately using the production C++ ReliableAudioLag.',
        '- Perfect clock mapping, no callback CPU contention, no audio device or time-stretch DSP. '
        'Presentation age adds an assumed 11 ms output reserve.',
        '- Unavailable source includes concealment, skipped source, and unfinished source. '
        'It is not an acoustic quality score. Concealment runs have 5 ms tick resolution.', '',
        '## Primary budget: target 50 ms / maximum 100 ms', '',
        '| Scenario | Transport model | Fixed | Speed only | Buffer only | Both |',
        '|---|---|---:|---:|---:|---:|']
    scenarios = sorted({row['scenario'] for row in rows})
    transports = sorted({row['transport'] for row in rows})
    policies = ['fixed', 'speed_only', 'buffer_only', 'adaptive']
    for scenario in scenarios:
        for transport in transports:
            values = [mean(r['unavailableSourcePercent'] for r in
                      aggregate[(scenario, transport, 50, 100, policy)]) for policy in policies]
            lines.append(f'| {scenario} | {transport} | ' + ' | '.join(f'{v:.3f}%' for v in values) + ' |')
    lines += ['', '## Paired differences from fixed control', '',
        'Negative differences indicate fewer unavailable source frames. Bootstrap intervals '
        'describe these eight synthetic seeds, not the population of real wireless networks.', '',
        '| Scenario | Transport | Target/max ms | Policy | Mean difference (pp) | Seed bootstrap 95% interval | Better/tie/worse |',
        '|---|---|---|---|---:|---|---|']
    paired_csv = []
    for key, values in sorted(differences.items()):
        scenario, transport, target, maximum, policy = key
        low, high = interval(values)
        better = sum(v < -1e-9 for v in values)
        worse = sum(v > 1e-9 for v in values)
        tie = len(values) - better - worse
        lines.append(f'| {scenario} | {transport} | {target:g}/{maximum:g} | {policy} | '
                     f'{mean(values):+.3f} | [{low:+.3f}, {high:+.3f}] | {better}/{tie}/{worse} |')
        paired_csv.append(dict(scenario=scenario, transport=transport, target_ms=target,
            maximum_ms=maximum, policy=policy, difference_pp=mean(values), low_pp=low,
            high_pp=high, better=better, tie=tie, worse=worse))
    lines += ['', '## Recovery snapshot audit', '',
        'Known receiver lag is measured at feedback generation time. The source is produced '
        'every 2.5 ms; feedback ages are multiples of 5 ms. Each snapshot is independent; '
        'this experiment does not predict the number of restarts in a live connection.', '',
        '| Transport budget ms | Eligible snapshots | Ignored stale snapshots | Old false positives | Corrected false positives | Old/corrected true positives | Corrected false negatives |',
        '|---|---:|---:|---:|---:|---:|---:|']
    for budget in sorted({row['budget_ms'] for row in recovery}):
        selected = [row for row in recovery if row['budget_ms'] == budget]
        def total(key):
            return sum(row[key] for row in selected)
        lines.append(f"| {budget} | {total('cases')-total('ignored')} | {total('ignored')} | "
            f"{total('old_false_positive')} | {total('corrected_false_positive')} | "
            f"{total('old_true_positive')}/{total('corrected_true_positive')} | {total('corrected_false_negative')} |")
    maximum = max(row.get('maxPresentationMilliseconds', 0) for row in rows)
    lines += ['', f'Maximum observed modeled presentation age across all cases: {maximum:.3f} ms.', '']
    (directory / 'summary.md').write_text('\n'.join(lines), encoding='utf-8')
    with (directory / 'paired.csv').open('w', newline='', encoding='utf-8') as output:
        writer = csv.DictWriter(output, fieldnames=list(paired_csv[0]))
        writer.writeheader()
        writer.writerows(paired_csv)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    write_report(parser.parse_args().directory)
