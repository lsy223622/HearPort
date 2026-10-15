import unittest
import json
import os
from pathlib import Path

import numpy as np

from diagnostics.music_plc import replay, arrival_trace, coverage_curve, CurrentConcealment, ar_predict


class Predictor:
    name = 'probe'

    def __init__(self):
        self.contexts = []

    def predict(self, history, frames):
        self.contexts.append(history.copy())
        level = float(np.mean(history)) if len(history) else 0
        return np.full((frames, 2), 0.125 + level * 0.1, dtype=np.float32)


class MusicPLCTests(unittest.TestCase):
    def audio(self):
        return np.full((480 * 8, 2), 0.25, dtype=np.float32)

    @unittest.skipUnless(os.environ.get('HEARPORT_MUSIC_REFERENCE'), 'Swift reference generated on macOS')
    def test_current_concealment_matches_actual_swift_across_bursts_and_recovery(self):
        records = json.loads(Path(os.environ['HEARPORT_MUSIC_REFERENCE']).read_text())
        model = CurrentConcealment()
        for record in records:
            if record['action'] == 'accept':
                actual = model.accept(np.asarray(record['input'], np.float32).reshape(-1, 2))
            else:
                actual = model.conceal(record['frames'])
            np.testing.assert_allclose(actual.ravel(), record['output'], rtol=0, atol=2e-6)

    def test_ar_extrapolates_a_stereo_tone_without_reversing_channels(self):
        source = np.sin(np.arange(2400) * 2 * np.pi * 440 / 48000).astype(np.float32)
        output = ar_predict(np.stack((source[:2000], -source[:2000]), axis=1), 120, order=64)
        self.assertLess(float(np.max(np.abs(output[:, 0] - source[2000:2120]))), 0.1)
        np.testing.assert_allclose(output[:, 0], -output[:, 1], atol=1e-6)

    def test_original_arriving_during_prediction_wins_without_polluting_history(self):
        audio = self.audio()
        arrivals = np.arange(32) * 2.5 + 1
        arrivals[8:12] = 108
        model = Predictor()
        result, output = replay(audio, arrivals, 100, model, execution_ms=4, margin_ms=2)
        np.testing.assert_array_equal(output, audio)
        self.assertGreater(result['unusedPredictions'], 0)
        self.assertEqual(result['unavailableSourceFrames'], 0)
        self.assertTrue(all(np.all(history == 0.25) for history in model.contexts))

    def test_prediction_finishing_after_commit_uses_immediate_fallback(self):
        arrivals = np.full(32, np.inf)
        result, output = replay(self.audio(), arrivals, 100, Predictor(), execution_ms=4,
                                margin_ms=2, runtime_ms=[8])
        self.assertGreater(result['predictionDeadlineMisses'], 0)
        self.assertTrue(np.all(output == 0))

    def test_unreceived_samples_do_not_leak_into_prediction(self):
        audio = self.audio()
        arrivals = np.arange(32) * 2.5 + 1
        arrivals[8:20] = np.inf
        _, expected = replay(audio, arrivals, 100, Predictor(), execution_ms=4, margin_ms=2)
        corrupted = audio.copy()
        corrupted[960:2400] = -0.9
        _, actual = replay(corrupted, arrivals, 100, Predictor(), execution_ms=4, margin_ms=2)
        np.testing.assert_array_equal(expected, actual)

    def test_compute_queue_continues_past_discarded_jobs(self):
        result, _ = replay(self.audio(), np.full(32, np.inf), 100, Predictor(),
                           execution_ms=4, margin_ms=2, runtime_ms=[30])
        self.assertGreater(result['maximumWorkerQueueMilliseconds'], 0)
        self.assertGreater(result['predictionDeadlineMisses'], 1)

    def test_budget_sweep_uses_identical_arrivals_and_cannot_fix_permanent_loss(self):
        arrivals = arrival_trace(48000 * 12, 'loss', 7)
        curve = coverage_curve(arrivals, [60, 100, 300])
        self.assertEqual(len({row['inputFingerprint'] for row in curve}), 1)
        self.assertEqual(len({row['unavailableSourceFrames'] for row in curve}), 1)
        burst = coverage_curve(arrival_trace(48000 * 12, 'stall200', 7), [60, 100, 300])
        self.assertGreater(burst[0]['unavailableSourceFrames'], burst[-1]['unavailableSourceFrames'])


if __name__ == '__main__':
    unittest.main()
