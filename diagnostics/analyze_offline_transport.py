"""Summarize deterministic, paired controller experiments."""

import argparse
import csv
import json
import random
from collections import defaultdict
from pathlib import Path
from statistics import mean


def paired_differences(rows, baseline='fixed'):
    grouped = defaultdict(dict)
    for row in rows:
        key = (row['scenario'], row['transport'], row['targetMilliseconds'],
               row['maximumMilliseconds'], row['seed'])
        grouped[key][row['policy']] = row
    differences = defaultdict(list)
    for key, policies in grouped.items():
        if baseline not in policies:
            raise ValueError(f'paired experiment has no {baseline} control')
        control = policies[baseline]
        for policy, row in policies.items():
            if row['inputFingerprint'] != control['inputFingerprint']:
                raise ValueError('paired policies used different network inputs')
            if policy != baseline:
                differences[key[:-1] + (policy,)].append(
                    row['unavailableSourcePercent'] - control['unavailableSourcePercent'])
    return differences


def recovery_differences(rows):
    grouped = defaultdict(dict)
    for row in rows:
        if row['transport'].startswith('reliable_'):
            key = (row['scenario'], row['targetMilliseconds'], row['maximumMilliseconds'],
                   row['policy'], row['seed'])
            grouped[key][row['transport']] = row
    differences = defaultdict(list)
    for key, transports in grouped.items():
        control = transports['reliable_legacy_recovery']
        corrected = transports['reliable_corrected_recovery']
        if corrected['inputFingerprint'] != control['inputFingerprint']:
            raise ValueError('recovery comparisons used different network inputs')
        differences[key[:-1]].append({
            'unavailable': corrected['unavailableSourcePercent'] - control['unavailableSourcePercent'],
            'restarts': corrected['restarts'] - control['restarts'],
            'replays': corrected['replayedPackets'] - control['replayedPackets'],
        })
    return differences


def interval(values):
    rng = random.Random(20261015)
    bootstraps = sorted(mean(rng.choices(values, k=len(values))) for _ in range(2000))
    return bootstraps[49], bootstraps[1949]


def experiment_pairs(rows, baseline_name='baseline'):
    axes = ('scenario', 'transport', 'targetMilliseconds', 'maximumMilliseconds',
            'feedbackIntervalMilliseconds', 'restartDelayMilliseconds',
            'recoveryLeadMilliseconds', 'sendMegabitsPerSecond', 'seed')
    grouped = defaultdict(dict)
    for row in rows:
        key = tuple(row.get(axis, 0) for axis in axes)
        experiment = row['experiment']
        if experiment in grouped[key]:
            raise ValueError('duplicate experimental result')
        grouped[key][experiment] = row
    pairs = []
    for key, variants in grouped.items():
        if baseline_name not in variants:
            raise ValueError('experiment has no matching baseline')
        baseline = variants[baseline_name]
        for experiment, row in variants.items():
            if row['inputFingerprint'] != baseline['inputFingerprint']:
                raise ValueError('experiment changed network input')
            if experiment == baseline_name:
                continue
            pair = dict(zip(axes, key))
            pair['experiment'] = experiment
            for metric in ('unavailableSourcePercent', 'outputGapPercent',
                           'p99PresentationMilliseconds', 'restarts', 'replayedPackets',
                           'skippedFrames', 'waitingOutputMilliseconds'):
                value, control = row.get(metric), baseline.get(metric)
                pair[metric + 'Difference'] = value - control if value is not None and control is not None else None
            pairs.append(pair)
    return pairs


def write_experiment_pairs(source, baseline_name='baseline'):
    pairs = experiment_pairs(json.loads(source.read_text(encoding='utf-8')), baseline_name)
    with source.with_suffix('.paired.csv').open('w', newline='', encoding='utf-8') as output:
        writer = csv.DictWriter(output, fieldnames=list(pairs[0]))
        writer.writeheader()
        writer.writerows(pairs)


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
        '- Executes the production Swift PlayoutController and ProbeConsumer. Only the guarded '
        'policy adds an experimental rule to a temporary controller copy: taper negative correction '
        'within 15 ms of the prepare deadline, reaching zero at 5 ms remaining.',
        '- Datagram delivers surviving packets independently. The reliable model assumes '
        'one successful retry per lost packet and ordered delivery with head-of-line blocking.',
        '- Closed-loop reliable variants call the production C++ ReliableAudioLag, cancel pending '
        'old-generation deliveries, and send fresh replays through the same impaired channel. '
        'Feedback every 50 ms uses an ordered return channel with 20–40 ms base delay and shared outages.',
        '- No congestion control, throughput limit, MsQuic ACK/PTO, restart handshake cost or '
        'connection failure. Legacy differs only by omitting feedback age from the lag threshold; '
        'both variants retain the current stale-feedback filter.',
        '- Perfect clock mapping, no callback CPU contention, no audio device or time-stretch DSP. '
        'Presentation age adds an assumed 11 ms output reserve.',
        '- Unavailable source includes concealment, skipped source, and unfinished source. '
        'It is not an acoustic quality score. Concealment runs have 5 ms tick resolution.', '',
        '## Primary budget: target 50 ms / maximum 100 ms', '',
        '| Scenario | Transport model | Fixed | Speed only | Buffer only | Both | Deadline guard |',
        '|---|---|---:|---:|---:|---:|---:|']
    scenarios = sorted({row['scenario'] for row in rows})
    transports = sorted({row['transport'] for row in rows})
    policies = ['fixed', 'speed_only', 'buffer_only', 'adaptive', 'guarded']
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
    lines += ['', '## Deadline guard versus adaptive (paired, all budgets)', '',
        '| Scenario | Transport | Target/max ms | Unavailable difference pp | Seed bootstrap interval | P99 age difference ms |',
        '|---|---|---|---:|---|---:|']
    for key, values in sorted(paired_differences(rows, baseline='adaptive').items()):
        scenario, transport, target, maximum, policy = key
        if policy != 'guarded':
            continue
        low, high = interval(values)
        guards = aggregate[(scenario, transport, target, maximum, 'guarded')]
        controls = aggregate[(scenario, transport, target, maximum, 'adaptive')]
        latency_delta = mean(r['p99PresentationMilliseconds'] for r in guards) - mean(
            r['p99PresentationMilliseconds'] for r in controls)
        lines.append(f'| {scenario} | {transport} | {target:g}/{maximum:g} | {mean(values):+.3f} | '
                     f'[{low:+.3f}, {high:+.3f}] | {latency_delta:+.3f} |')
    lines += ['', '## Closed-loop recovery: corrected minus legacy (paired)', '',
        '| Scenario | Target/max ms | Policy | Unavailable difference pp | Seed bootstrap interval | Restart difference | Replay difference |',
        '|---|---|---|---:|---|---:|---:|']
    for key, values in sorted(recovery_differences(rows).items()):
        scenario, target, maximum, policy = key
        delta = [v['unavailable'] for v in values]
        low, high = interval(delta)
        lines.append(f'| {scenario} | {target:g}/{maximum:g} | {policy} | {mean(delta):+.3f} | '
            f'[{low:+.3f}, {high:+.3f}] | {mean(v["restarts"] for v in values):+.3f} | '
            f'{mean(v["replays"] for v in values):+.3f} |')
    lines += ['', '## Closed-loop recovery totals (mean per seed)', '',
        '| Scenario | Transport | Target/max ms | Policy | Restarts | Replays | Canceled pending packets |',
        '|---|---|---|---|---:|---:|---:|']
    for key, selected in sorted(aggregate.items()):
        scenario, transport, target, maximum, policy = key
        if transport not in ('reliable_legacy_recovery', 'reliable_corrected_recovery'):
            continue
        lines.append(f'| {scenario} | {transport} | {target:g}/{maximum:g} | {policy} | '
            f'{mean(r["restarts"] for r in selected):.3f} | {mean(r["replayedPackets"] for r in selected):.3f} | '
            f'{mean(r["canceledPackets"] for r in selected):.3f} |')
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
    directory = parser.parse_args().directory
    if (directory / 'playout.json').exists():
        write_report(directory)
    for name in ('ablation', 'components', 'sensitivity', 'capacity', 'replay'):
        source = directory / f'{name}.json'
        if source.exists():
            write_experiment_pairs(source)
    source = directory / 'projection.json'
    if source.exists():
        write_experiment_pairs(source, baseline_name='bounded_replay')
