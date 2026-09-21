import unittest

from tests.reference.realtime_core import (
    DriftController,
    JitterBuffer,
    RenderRingBuffer,
    is_newer,
)
from tests.reference.wire_codec import AudioDatagram


PCM = bytes(960)


def packet(stream_id: int, sequence: int, marker: int = 0) -> AudioDatagram:
    return AudioDatagram(stream_id, sequence, bytes([marker]) + bytes(959))


class SequenceTests(unittest.TestCase):
    def test_modular_order_handles_uint32_wrap(self):
        self.assertTrue(is_newer(0, 0xFFFFFFFF))
        self.assertTrue(is_newer(1, 0))
        self.assertFalse(is_newer(0xFFFFFFFF, 0))
        self.assertFalse(is_newer(7, 7))


class JitterBufferTests(unittest.TestCase):
    def test_startup_waits_for_target_then_consumes_in_sequence(self):
        jitter = JitterBuffer(stream_id=5, capacity_packets=8, target_packets=2)
        self.assertEqual(jitter.insert(packet(5, 100, 100)), "accepted")
        self.assertEqual(jitter.mode, "buffering")
        self.assertEqual(jitter.insert(packet(5, 101, 101)), "accepted")
        self.assertEqual(jitter.mode, "playing")
        self.assertEqual(jitter.consume_next().sequence, 100)
        self.assertEqual(jitter.consume_next().sequence, 101)

    def test_duplicate_late_and_wrong_stream_are_classified(self):
        jitter = JitterBuffer(stream_id=5, capacity_packets=8, target_packets=1)
        self.assertEqual(jitter.insert(packet(5, 10)), "accepted")
        self.assertEqual(jitter.insert(packet(5, 11)), "accepted")
        self.assertEqual(jitter.insert(packet(5, 11)), "duplicate")
        self.assertEqual(jitter.consume_next().sequence, 10)
        self.assertEqual(jitter.insert(packet(5, 10)), "late")
        self.assertEqual(jitter.insert(packet(6, 12)), "wrong_stream")

    def test_missing_concealment_advances_cursor_and_late_packet_is_dropped(self):
        jitter = JitterBuffer(stream_id=5, capacity_packets=8, target_packets=1)
        jitter.insert(packet(5, 20, 20))
        jitter.insert(packet(5, 22, 22))
        self.assertEqual(jitter.consume_next().sequence, 20)
        self.assertEqual(jitter.conceal_missing(), PCM)
        self.assertEqual(jitter.stats.loss, 1)
        self.assertEqual(jitter.insert(packet(5, 21)), "late")
        self.assertEqual(jitter.consume_next().sequence, 22)

    def test_silent_rebuffer_does_not_manufacture_packet_loss(self):
        jitter = JitterBuffer(stream_id=5, capacity_packets=8, target_packets=2)
        jitter.insert(packet(5, 30))
        jitter.insert(packet(5, 31))
        jitter.enter_silent_rebuffer()
        self.assertEqual(jitter.mode, "silent_rebuffer")
        self.assertEqual(jitter.stats.loss, 0)
        jitter.insert(packet(5, 100))
        jitter.insert(packet(5, 101))
        self.assertEqual(jitter.mode, "playing")

    def test_reset_replaces_stream_and_discards_old_packets(self):
        jitter = JitterBuffer(stream_id=5, capacity_packets=8, target_packets=1)
        jitter.insert(packet(5, 40))
        jitter.reset(9)
        self.assertEqual(jitter.stream_id, 9)
        self.assertEqual(jitter.mode, "buffering")
        self.assertEqual(jitter.stats.loss, 0)
        self.assertEqual(jitter.insert(packet(5, 41)), "wrong_stream")
        self.assertEqual(jitter.insert(packet(9, 1)), "accepted")


class RenderRingBufferTests(unittest.TestCase):
    def test_capacity_is_bounded_and_counts_overflow_underflow(self):
        ring = RenderRingBuffer(capacity_frames=4)
        self.assertEqual(ring.write([1, 2, 3, 4, 5]), 4)
        self.assertEqual(ring.stats.overflow_frames, 1)
        self.assertEqual(ring.read(3), [1, 2, 3])
        self.assertEqual(ring.read(3), [4])
        self.assertEqual(ring.stats.underflow_frames, 2)


class DriftControllerTests(unittest.TestCase):
    def test_fill_error_is_low_passed_and_correction_is_bounded(self):
        controller = DriftController(target_frames=480)
        ratios = [controller.update(600, valid_audio=True, nominal_ratio=1.0) for _ in range(20)]
        self.assertGreater(ratios[-1], 1.0)
        self.assertLess(ratios[-1], 1.002)
        self.assertGreater(ratios[1] - ratios[0], 0.0)

    def test_invalid_audio_freezes_ratio_and_reset_returns_nominal(self):
        controller = DriftController(target_frames=480)
        active = controller.update(600, valid_audio=True, nominal_ratio=1.0)
        frozen = controller.update(100, valid_audio=False, nominal_ratio=1.0)
        self.assertEqual(frozen, active)
        controller.reset()
        self.assertEqual(controller.update(480, valid_audio=True, nominal_ratio=1.0), 1.0)


if __name__ == "__main__":
    unittest.main()
