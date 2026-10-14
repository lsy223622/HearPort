import unittest

from diagnostics.analyze_offline_transport import interval, paired_differences


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


if __name__ == '__main__':
    unittest.main()
