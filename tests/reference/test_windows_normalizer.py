import struct
import unittest

from tests.reference.windows_audio import AudioPacketizer, PcmNormalizer


class WindowsAudioTests(unittest.TestCase):
    def test_mono_int16_is_decoded_and_duplicated_to_stereo(self):
        source = struct.pack("<hhh", 0, 32767, -32768)
        normalizer = PcmNormalizer(sample_rate_hz=48000, channels=1, sample_format="int16le")
        output = normalizer.convert(source)
        self.assertEqual(len(output), 6)
        self.assertEqual(output[0:2], [0.0, 0.0])
        self.assertAlmostEqual(output[2], 32767 / 32768, places=6)
        self.assertAlmostEqual(output[3], 32767 / 32768, places=6)
        self.assertEqual(output[4:6], [-1.0, -1.0])

    def test_float32_stereo_at_canonical_rate_is_preserved(self):
        source = struct.pack("<ffff", 0.25, -0.5, 0.75, -1.0)
        normalizer = PcmNormalizer(sample_rate_hz=48000, channels=2, sample_format="float32le")
        self.assertEqual(normalizer.convert(source), [0.25, -0.5, 0.75, -1.0])

    def test_mono_24_bit_44_1_khz_is_resampled_to_stereo_48_khz(self):
        source = b"".join(
            value.to_bytes(3, "little", signed=True)
            for value in (0, 0x7FFFFF, -0x800000)
        )
        normalizer = PcmNormalizer(sample_rate_hz=44100, channels=1, sample_format="int24le")
        output = normalizer.convert(source)
        self.assertEqual(len(output) % 2, 0)
        self.assertEqual(len(output) // 2, 3)
        for frame in range(3):
            self.assertAlmostEqual(output[frame * 2], output[frame * 2 + 1], places=6)

    def test_packetizer_emits_exactly_120_frames_and_keeps_remainder(self):
        packetizer = AudioPacketizer(stream_id=9)
        frames = [value for frame in range(121) for value in (frame / 121, -frame / 121)]
        packets = packetizer.push(frames)
        self.assertEqual(len(packets), 1)
        self.assertEqual(packets[0].stream_id, 9)
        self.assertEqual(packets[0].sequence, 0)
        self.assertEqual(packetizer.buffered_frames, 1)
        packets = packetizer.push([0.0, 0.0] * 119)
        self.assertEqual(len(packets), 1)
        self.assertEqual(packets[0].sequence, 1)
        self.assertEqual(packetizer.buffered_frames, 0)


if __name__ == "__main__":
    unittest.main()
