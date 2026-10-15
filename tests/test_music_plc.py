import unittest
import json
import os
from pathlib import Path

import numpy as np

from diagnostics.music_plc import replay, arrival_trace, coverage_curve, CurrentConcealment, ar_predict, quality


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

    def test_ar_handles_loss_before_any_committed_history(self):
        from diagnostics.music_plc import Autoregressive
        arrivals = np.arange(32) * 2.5 + 1
        arrivals[:4] = np.inf
        result, output = replay(self.audio(), arrivals, 100, Autoregressive(), execution_ms=4,
                                runtime_ms=[1])
        self.assertEqual(result['unavailableSourceFrames'], 480)
        self.assertTrue(np.all(np.isfinite(output)))
        np.testing.assert_array_equal(output[:480], 0)

    def test_current_reference_matches_packetwise_state_in_partially_missing_blocks(self):
        t = np.arange(480 * 8) / 48000
        audio = np.stack((0.3 * np.sin(2 * np.pi * (220 * t + 100 * t * t)),
                          0.2 * np.sin(2 * np.pi * 330 * t)), axis=1).astype(np.float32)
        arrivals = np.arange(32) * 2.5 + 1
        arrivals[19] = np.inf
        _, output = replay(audio, arrivals, 100, CurrentConcealment(), execution_ms=4, runtime_ms=[0])
        baseline = CurrentConcealment()
        expected = np.concatenate([baseline.conceal(120) if i == 19 else baseline.accept(audio[i*120:(i+1)*120])
                                   for i in range(32)])
        np.testing.assert_array_equal(output, expected)

    def test_quality_detects_recovery_damage_outside_missing_packet(self):
        audio = self.audio()
        missing = np.zeros(32, bool)
        missing[12] = True
        unchanged = quality(audio, audio, missing)
        damaged = audio.copy()
        damaged[13*120:14*120] = 0
        changed = quality(audio, damaged, missing)
        self.assertEqual(unchanged['gapRecoveryLogMagnitudeError'], 0)
        self.assertGreater(changed['gapRecoveryLogMagnitudeError'], 0)

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

    def test_future_context_contains_only_packets_received_before_launch(self):
        class FutureProbe(Predictor):
            def predict(self, history, frames):
                self.contexts.append(None if self.future is None else self.future.copy())
                return np.zeros((frames, 2), np.float32)
        arrivals = np.full(32, np.inf)
        arrivals[12:16] = 108
        model = FutureProbe()
        replay(self.audio(), arrivals, 100, model, execution_ms=4, margin_ms=2)
        self.assertIsNone(model.contexts[2])
        arrivals[12:16] = 102
        model = FutureProbe()
        replay(self.audio(), arrivals, 100, model, execution_ms=4, margin_ms=2)
        self.assertEqual(len(model.contexts[2]), 480)

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
