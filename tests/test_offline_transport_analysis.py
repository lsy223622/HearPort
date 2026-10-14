import unittest

from diagnostics.analyze_offline_transport import interval, paired_differences, recovery_differences


class OfflineTransportAnalysisTests(unittest.TestCase):
    def row(self, seed, policy, unavailable, fingerprint='same'):
        return dict(scenario='jitter', transport='datagram', targetMilliseconds=50,
            maximumMilliseconds=100, seed=seed, policy=policy,
            unavailableSourcePercent=unavailable, inputFingerprint=fingerprint)

    def test_pairing_preserves_seed_instead_of_pooling_different_inputs(self):
        rows = [self.row(1, 'fixed', 10), self.row(1, 'adaptive', 9),
                self.row(2, 'fixed', 2), self.row(2, 'adaptive', 4)]
        result = paired_differences(rows)
        self.assertEqual(list(result.values()), [[-1, 2]])

    def test_mismatched_input_and_missing_control_are_rejected(self):
        with self.assertRaises(ValueError):
            paired_differences([self.row(1, 'fixed', 1), self.row(1, 'adaptive', 0, 'different')])
        with self.assertRaises(ValueError):
            paired_differences([self.row(1, 'adaptive', 0)])

    def test_interval_is_repeatable_and_preserves_a_constant_difference(self):
        self.assertEqual(interval([-2] * 8), (-2, -2))
        self.assertEqual(interval([-1, 0, 1, 2]), interval([-1, 0, 1, 2]))

    def test_guard_compares_against_adaptive_with_same_transport(self):
        rows = [self.row(1, 'fixed', 10), self.row(1, 'adaptive', 8), self.row(1, 'guarded', 7)]
        result = paired_differences(rows, baseline='adaptive')
        self.assertEqual(result[('jitter', 'datagram', 50, 100, 'guarded')], [-1])

    def test_recovery_comparison_keeps_policy_and_seed_paired(self):
        rows = []
        for seed, policy, legacy, corrected in [(1, 'fixed', 5, 4), (2, 'adaptive', 2, 3)]:
            for transport, unavailable, restarts in [('reliable_legacy_recovery', legacy, 4),
                                                     ('reliable_corrected_recovery', corrected, 2)]:
                row = self.row(seed, policy, unavailable)
                row.update(transport=transport, restarts=restarts, replayedPackets=10)
                rows.append(row)
        result = recovery_differences(rows)
        self.assertEqual(result[('jitter', 50, 100, 'fixed')][0]['unavailable'], -1)
        self.assertEqual(result[('jitter', 50, 100, 'adaptive')][0]['unavailable'], 1)
        self.assertEqual(result[('jitter', 50, 100, 'fixed')][0]['restarts'], -2)
        rows[-1]['inputFingerprint'] = 'different'
        with self.assertRaises(ValueError):
            recovery_differences(rows)


if __name__ == '__main__':
    unittest.main()
