"""Local music PLC experiments with a fixed 2.5 ms packet submission schedule.

This isolates concealment and prediction scheduling; it is not the production
adaptive receiver or an iPad performance measurement. Audio never leaves disk.
"""
import argparse
import ast
import copy
import hashlib
import json
import platform
import time
import os
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np

RATE = 48000
PACKET = 120
BLOCK = 480
RESERVE_MS = 11


class CurrentConcealment:
    """Numerical reference for the production MusicConcealment algorithm."""
    name = 'current'

    def __init__(self):
        self.history = np.empty((0, 2), np.float32)
        self.period = 120
        self.missing = 0
        self.last = np.zeros(2, np.float32)

    def accept(self, audio):
        output = audio.copy()
        if self.missing:
            fade = min(PACKET, len(output))
            weight = np.arange(1, fade + 1, dtype=np.float32)[:, None] / fade
            output[:fade] = self.last * (1 - weight) + output[:fade] * weight
        self.missing = 0
        self.history = np.concatenate((self.history, audio))[-960:]
        if len(output):
            self.last = output[-1].copy()
        return output

    def conceal(self, frames):
        available = len(self.history)
        if available < 96:
            return np.zeros((frames, 2), np.float32)
        if self.missing == 0:
            errors = []
            for lag in range(48, min(480, available // 2) + 1):
                length = min(PACKET, available - lag)
                a = self.history[-length:].astype(np.float64)
                b = self.history[available - lag - length:available - lag].astype(np.float64)
                errors.append(np.sum((a - b) ** 2))
            self.period = 48 + int(np.argmin(errors))
        positions = available - self.period + (self.missing + np.arange(frames)) % self.period
        gain = np.exp(-(self.missing + np.arange(frames)) / 480).astype(np.float32)
        output = self.history[positions] * gain[:, None]
        self.missing += frames
        self.last = output[-1].copy()
        return output

    def predict(self, history, frames):
        state = copy.deepcopy(self.state)
        return np.concatenate([state.conceal(min(PACKET, frames - i))
                               for i in range(0, frames, PACKET)])


def ar_predict(history, frames, order=256):
    from scipy.linalg import solve_toeplitz
    from scipy.signal import correlate, lfiltic, lfilter
    result = []
    for channel in history.T:
        channel = np.pad(channel.astype(np.float64), (max(0, order + 1 - len(channel)), 0))
        acf = correlate(channel, channel, method='fft')[len(channel) - 1:len(channel) + order]
        column = acf[:order].copy()
        column[0] += 0.001
        coefficients = solve_toeplitz(column, acf[1:order + 1])
        denominator = np.r_[1, -coefficients]
        initial = lfiltic([1], denominator, channel[-order:][::-1])
        prediction, _ = lfilter([1], denominator, np.zeros(frames), zi=initial)
        if not np.all(np.isfinite(prediction)) or np.max(np.abs(prediction)) > 1.5:
            prediction[:] = 0
        result.append(prediction)
    return np.stack(result, axis=1).astype(np.float32)


class Autoregressive:
    name = 'ar256'

    def predict(self, history, frames):
        return ar_predict(history[-4800:], frames)


class BidirectionalAR(Autoregressive):
    name = 'ar256_available_future'

    def predict(self, history, frames):
        forward = super().predict(history, frames)
        if self.future is None or len(self.future) < 256:
            return forward
        backward = ar_predict(self.future[::-1], frames)[::-1]
        weight = np.linspace(0, 1, frames, dtype=np.float32)[:, None]
        return forward * (1 - weight) + backward * weight


class PARCnet:
    name = 'parcnet32k'
    predictionFrames = BLOCK

    def __init__(self, source, checkpoint):
        import torch
        import torch.nn as nn
        tree = ast.parse(source.read_text(encoding='utf-8'))
        classes = [node for node in tree.body if isinstance(node, ast.ClassDef)
                   and node.name != 'HybridModel']
        namespace = dict(torch=torch, nn=nn)
        exec(compile(ast.Module(body=classes, type_ignores=[]), str(source), 'exec'), namespace)
        self.torch = torch
        self.network = namespace['Generator'](channels=1, lite=True)
        state = torch.load(checkpoint, map_location='cpu', weights_only=True)['state_dict']
        self.network.load_state_dict({key.removeprefix('generator.'): value for key, value in state.items()
                                      if key.startswith('generator.')}, strict=True)
        self.network.eval()

    def predict(self, history, frames):
        from scipy.signal import resample_poly
        if not 0 < frames <= BLOCK:
            raise ValueError('original PARCnet probe predicts at most 10 ms ahead')
        past = resample_poly(history[-4800:], 2, 3, axis=0).astype(np.float32)
        past = np.pad(past, ((max(0, 3200 - len(past)), 0), (0, 0)))
        ar = ar_predict(past[-3200:], 400, order=128)
        context = np.pad(past[-2240:].T[:, None, :], ((0, 0), (0, 0), (0, 400)))
        with self.torch.inference_mode():
            residual = self.network(self.torch.from_numpy(context))[..., -400:].numpy()[:, 0, :].T
        residual[:16] *= np.linspace(0, 1, 16)[:, None]
        return resample_poly(ar + residual, 3, 2, axis=0)[:frames].astype(np.float32)


def arrival_trace(frames, scenario, seed):
    count = frames // PACKET
    random = np.random.default_rng(seed)
    capture = np.arange(count) * 2.5
    arrival = capture + random.uniform(4, 12, count)
    for start in np.arange(2000, frames / 48 - 500, 2000):
        duration = {'burst': 50, 'hol': 100, 'stall200': 200, 'drop300': 300}.get(scenario, 0)
        held = (capture >= start) & (capture < start + duration)
        if scenario == 'drop300':
            arrival[held] = np.inf
        else:
            arrival[held] = start + duration + 5
    if scenario == 'loss':
        arrival[random.random(count) < 0.01] = np.inf
    if scenario == 'hol':
        arrival = np.maximum.accumulate(arrival)
    return arrival


def missing_summary(missing):
    padded = np.r_[False, missing, False].astype(np.int8)
    starts = np.flatnonzero(np.diff(padded) == 1)
    ends = np.flatnonzero(np.diff(padded) == -1)
    return dict(unavailableSourceFrames=int(np.sum(missing)) * PACKET,
                gapCount=len(starts), longestGapMilliseconds=float(max(ends - starts, default=0)) * 2.5)


def coverage_curve(arrivals, budgets):
    fingerprint = hashlib.sha256(np.asarray(arrivals, dtype='<f8').tobytes()).hexdigest()
    rows = []
    for budget in budgets:
        commits = np.arange(len(arrivals)) * 2.5 + budget - RESERVE_MS
        missing = arrivals > commits
        rows.append(dict(budgetMilliseconds=budget, inputFingerprint=fingerprint,
                         **missing_summary(missing)))
    return rows


def replay(audio, arrivals, budget, predictor, execution_ms, margin_ms=1, runtime_ms=None, executor=None):
    if execution_ms + margin_ms > 10 or execution_ms < 0 or margin_ms < 0:
        raise ValueError('prediction lead must fit within this probe\'s 10 ms committed-history window')
    count = len(audio) // PACKET
    output = np.zeros((count * PACKET, 2), np.float32)
    baseline = CurrentConcealment()
    busy_until = -np.inf
    jobs = misses = 0
    maximum_queue = 0.0
    elapsed = []
    missing = np.zeros(count, dtype=bool)
    commits = np.arange(count) * 2.5 + budget - RESERVE_MS
    events = sorted([(commit - execution_ms - margin_ms, packet, 0) for packet, commit in enumerate(commits)] +
                    [(commit, packet, 1) for packet, commit in enumerate(commits)])
    pending = {}
    epoch = 0
    used_jobs = set()
    committed = compute_fallback = 0
    rejected = 0
    for now, packet, is_commit in events:
        begin = packet * PACKET
        if not is_commit:
            if isinstance(predictor, CurrentConcealment) or arrivals[packet] <= now:
                continue
            cached = pending.get(packet)
            if cached is not None and (cached[2] == epoch or cached[4] == packet):
                continue
            if max(now, busy_until) + execution_ms > commits[packet]:
                rejected += 1
                continue
            before = time.perf_counter_ns()
            state = copy.deepcopy(baseline)
            anchor = committed
            context = output[max(0, anchor * PACKET - 4800):anchor * PACKET].copy()
            while anchor < packet and arrivals[anchor] <= now:
                known = state.accept(audio[anchor * PACKET:(anchor + 1) * PACKET])
                context = np.concatenate((context, known))[-4800:]
                anchor += 1
            frames = (packet + 1 - anchor) * PACKET
            frames = max(frames, getattr(predictor, 'predictionFrames', 0))
            predictor.state = state
            future_end = packet + 1
            while future_end < min(count, packet + 9) and arrivals[future_end] <= now:
                future_end += 1
            predictor.future = audio[begin + PACKET:future_end * PACKET] if future_end > packet + 1 else None
            candidate = (executor.submit(predictor.predict, context, frames).result() if executor
                         else predictor.predict(context, frames))
            duration = (time.perf_counter_ns() - before) / 1e6
            elapsed.append(duration)
            duration = runtime_ms[jobs % len(runtime_ms)] if runtime_ms is not None else duration
            start = max(now, busy_until)
            maximum_queue = max(maximum_queue, start - now)
            ready = start + duration
            busy_until = ready
            jobs += 1
            for predicted in range(packet, min(count, anchor + frames // PACKET)):
                offset = (predicted - anchor) * PACKET
                pending[predicted] = (candidate[offset:offset + PACKET], ready, epoch, jobs, packet)
            if ready > commits[packet]:
                misses += 1
            continue
        candidate, ready, branch, job, origin = pending.pop(packet, (None, np.inf, epoch, 0, packet))
        if branch != epoch and origin != packet:
            candidate = None
        original = arrivals[packet] <= now
        missing[packet] = not original
        if original:
            selected = baseline.accept(audio[begin:begin + PACKET])
            epoch += 1
        else:
            selected = baseline.conceal(PACKET)
            if candidate is not None and ready <= now:
                selected = candidate
                baseline.last = selected[-1].copy()
                used_jobs.add(job)
            elif not isinstance(predictor, CurrentConcealment):
                compute_fallback += PACKET
        output[begin:begin + PACKET] = selected
        committed = packet + 1
    execution_model = ('instantaneous_packetwise_quality_reference' if isinstance(predictor, CurrentConcealment)
                       else 'measured_single_worker_2.5ms_packets')
    return dict(**missing_summary(missing), executionModel=execution_model, predictions=jobs, unusedPredictions=jobs-len(used_jobs),
                predictionDeadlineMisses=misses, maximumWorkerQueueMilliseconds=maximum_queue,
                deadlineQueueRejections=rejected, computeFallbackSourceFrames=compute_fallback,
                executionMilliseconds=elapsed), output


def quality(reference, output, missing):
    mask = np.repeat(missing, PACKET)[:len(output)]
    if not np.any(mask):
        return dict(gapSDRDecibels=None, gapErrorRMS=0.0, gapRecoveryLogMagnitudeError=None)
    clean = reference[:len(output)][mask].astype(np.float64)
    error = output[mask].astype(np.float64) - clean
    spectral = []
    for size in (240, 960, 1920):
        centers = np.arange(size // 2, len(output) - size // 2, PACKET)
        affected = np.convolve(missing.astype(np.int32), np.ones(2 + size // PACKET, np.int32), mode='same')
        centers = centers[affected[centers // PACKET] > 0]
        if not len(centers):
            continue
        window = np.hanning(size)[None, :, None]
        error_sum, bins = 0.0, 0
        for begin in range(0, len(centers), 128):
            positions = centers[begin:begin + 128, None] + np.arange(size) - size // 2
            a = np.abs(np.fft.rfft(reference[positions] * window, axis=1))
            b = np.abs(np.fft.rfft(output[positions] * window, axis=1))
            error_sum += float(np.sum(np.abs(np.log1p(a) - np.log1p(b))))
            bins += a.size
        spectral.append(error_sum / bins)
    return dict(gapSDRDecibels=float(10 * np.log10((np.sum(clean ** 2) + 1e-15) /
                                                 (np.sum(error ** 2) + 1e-15))),
                gapErrorRMS=float(np.sqrt(np.mean(error ** 2))),
                gapRecoveryLogMagnitudeError=float(np.mean(spectral)) if spectral else None)


def main():
    implementation_hash = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audio', type=Path)
    parser.add_argument('--start', type=float, default=30)
    parser.add_argument('--seconds', type=float, default=120)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--vendor', type=Path)
    parser.add_argument('--algorithms', nargs='+', choices=['current', 'ar256', 'ar256_available_future', 'parcnet32k'])
    parser.add_argument('--seeds', nargs='+', type=int, default=[1, 7, 19])
    parser.add_argument('--budgets', nargs='+', type=float, default=[80, 120, 200])
    parser.add_argument('--arrivals', type=Path, help='local NumPy array of arrival times in ms on the source timeline')
    parser.add_argument('--quality-only', action='store_true',
                        help='zero compute-cost quality ceiling; never a real-time eligibility result')
    args = parser.parse_args()
    if args.audio is None:
        from tkinter import Tk, filedialog
        root = Tk(); root.withdraw()
        chosen = filedialog.askopenfilename(title='Select local music for PLC comparison')
        root.destroy()
        if not chosen:
            parser.error('no audio selected')
        args.audio = Path(chosen)
    import soundfile as sf
    from scipy.signal import resample_poly
    from math import gcd
    with sf.SoundFile(args.audio) as source:
        rate = source.samplerate
        source.seek(round(args.start * rate))
        audio = source.read(round(args.seconds * rate), dtype='float32', always_2d=True)
    if audio.shape[1] == 1:
        audio = np.repeat(audio, 2, axis=1)
    if audio.shape[1] != 2 or len(audio) < rate * 5:
        raise ValueError('select at least five seconds of mono or stereo audio')
    divisor = gcd(rate, RATE)
    audio = resample_poly(audio, RATE // divisor, rate // divisor, axis=0).astype(np.float32)
    audio = audio[:len(audio) // BLOCK * BLOCK]
    args.output.mkdir(parents=True, exist_ok=False)
    sf.write(args.output / 'reference.wav', audio, RATE, subtype='FLOAT')
    models = [CurrentConcealment, Autoregressive, BidirectionalAR]
    executor = ThreadPoolExecutor(max_workers=1)
    load = {}
    if args.vendor and (args.algorithms is None or 'parcnet32k' in args.algorithms):
        before = time.perf_counter_ns()
        import torch
        torch.set_num_threads(1)
        torch.set_num_interop_threads(1)
        model = PARCnet(args.vendor / 'model-32k.py', args.vendor / 'parcnet-32k.ckpt')
        load[model.name] = dict(loadMilliseconds=(time.perf_counter_ns() - before) / 1e6,
                                checkpointSHA256=hashlib.sha256((args.vendor / 'parcnet-32k.ckpt').read_bytes()).hexdigest(),
                                modelSourceSHA256=hashlib.sha256((args.vendor / 'model-32k.py').read_bytes()).hexdigest(),
                                torchVersion=torch.__version__)
        models.append(lambda model=model: model)
    if args.algorithms:
        models = [factory for factory in models if factory().name in args.algorithms]
        if {factory().name for factory in models} != set(args.algorithms):
            parser.error('PARCnet requires --vendor with matching official source and checkpoint')
    budgets = [60, 80, 100, 120, 160, 200, 300]
    scenarios = ('recorded',) if args.arrivals else ('healthy', 'burst', 'hol', 'stall200', 'drop300', 'loss')
    seeds = [1] if args.arrivals else args.seeds
    recorded = np.load(args.arrivals, allow_pickle=False) if args.arrivals else None
    if recorded is not None and (recorded.shape != (len(audio) // PACKET,) or np.any(np.isnan(recorded))):
        raise ValueError('arrival array must contain one finite time or infinity per 2.5 ms packet')
    rows, curves, timing, excluded = [], [], {}, {}
    warm_history = audio[:4800]
    for factory in models:
        model = factory()
        if model.name in timing:
            raise ValueError(f'duplicate algorithm: {model.name}')
        model.state = CurrentConcealment()
        model.state.accept(warm_history)
        model.future = audio[4800:5760]
        durations = []
        for _ in range(25):
            before = time.perf_counter_ns()
            executor.submit(model.predict, warm_history, BLOCK).result()
            durations.append((time.perf_counter_ns() - before) / 1e6)
        idle = []
        for _ in range(8):
            time.sleep(0.1)
            before = time.perf_counter_ns()
            executor.submit(model.predict, warm_history, BLOCK).result()
            idle.append((time.perf_counter_ns() - before) / 1e6)
        long_idle = []
        for _ in range(3):
            time.sleep(1)
            before = time.perf_counter_ns()
            executor.submit(model.predict, warm_history, BLOCK).result()
            long_idle.append((time.perf_counter_ns() - before) / 1e6)
        timing[model.name] = dict(firstMilliseconds=durations[0], warmP50Milliseconds=float(np.median(durations[5:])),
                                 warmP99Milliseconds=float(np.percentile(durations[5:], 99)),
                                 warmMaximumMilliseconds=max(durations[5:]),
                                 idle100msWakeMaximumMilliseconds=max(idle),
                                 idle1000msWakeMaximumMilliseconds=max(long_idle))
    for scenario in scenarios:
        for seed in seeds:
            arrivals = recorded if recorded is not None else arrival_trace(len(audio), scenario, seed)
            curves.extend(dict(scenario=scenario, seed=seed, **row) for row in coverage_curve(arrivals, budgets))
            for factory in models:
                for budget in args.budgets:
                    model = factory()
                    lead = max(timing[model.name]['warmMaximumMilliseconds'],
                               timing[model.name]['idle100msWakeMaximumMilliseconds'],
                               timing[model.name]['idle1000msWakeMaximumMilliseconds'])
                    if isinstance(model, CurrentConcealment) or args.quality_only:
                        lead = 0
                    if lead + 1 > 10:
                        excluded[model.name] = 'measured Python worker cost exceeds this 10 ms reference window; iPad untested'
                        continue
                    result, output = replay(audio, arrivals, budget, model,
                        execution_ms=lead, margin_ms=0 if args.quality_only else 1,
                        runtime_ms=[0] if args.quality_only else None, executor=executor)
                    if args.quality_only and not isinstance(model, CurrentConcealment):
                        result['executionModel'] = 'zero_compute_cost_quality_ceiling'
                    commits = np.arange(len(arrivals)) * 2.5 + budget - RESERVE_MS
                    result.update(quality(audio, output, arrivals > commits))
                    elapsed = result.pop('executionMilliseconds')
                    result.update(scenario=scenario, seed=seed, algorithm=model.name, budgetMilliseconds=budget,
                        inputFingerprint=hashlib.sha256(arrivals.astype('<f8').tobytes()).hexdigest(),
                        inferenceP99Milliseconds=float(np.percentile(elapsed, 99)) if elapsed else None,
                        outputPeak=float(np.max(np.abs(output))))
                    assert np.all(np.isfinite(output))
                    rows.append(result)
                    if seed == 1 and budget == args.budgets[len(args.budgets) // 2] and scenario in ('stall200', 'loss', 'recorded'):
                        sf.write(args.output / f'{scenario}-{budget:g}-{model.name}.wav', output, RATE, subtype='FLOAT')
            (args.output / 'results.json').write_text(json.dumps(dict(scope='fixed_2.5ms_reference_not_production_or_ipad',
                platform=platform.platform(), audioSHA256=hashlib.sha256(audio.tobytes()).hexdigest(),
                implementationSHA256=implementation_hash,
                durationSeconds=len(audio) / RATE, qualityOnly=args.quality_only, load=load, timing=timing,
                excluded=excluded, coverage=curves, comparisons=rows), indent=2), encoding='utf-8')
            print(f'completed {scenario} seed={seed}', flush=True)
    executor.shutdown()
    os.environ.setdefault('MPLCONFIGDIR', str(args.output / 'matplotlib-cache'))
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    for scenario in scenarios:
        selected = [row for row in curves if row['scenario'] == scenario]
        values = [np.mean([row['unavailableSourceFrames'] / len(audio) * 100 for row in selected
                           if row['budgetMilliseconds'] == budget]) for budget in budgets]
        plt.plot(budgets, values, marker='o', label=scenario)
    plt.xlabel('End-to-end budget (ms); 11 ms output reserve included')
    plt.ylabel('Unavailable original source (%)')
    plt.title('Identical arrivals; fixed 2.5 ms submission reference')
    plt.legend(); plt.grid(alpha=0.3); plt.tight_layout()
    plt.savefig(args.output / 'latency-coverage.png', dpi=160)


if __name__ == '__main__':
    main()
