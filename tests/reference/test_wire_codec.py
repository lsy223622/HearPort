import unittest

from tests.reference.wire_codec import (
    AudioDatagram,
    AudioDatagramError,
    ControlFrameDecoder,
    ControlFrameError,
    decode_audio_datagram,
    encode_audio_datagram,
    encode_control_frame,
)


class ControlFramingTests(unittest.TestCase):
    def test_encodes_big_endian_length(self):
        self.assertEqual(encode_control_frame(b"abc"), b"\x00\x00\x00\x03abc")

    def test_decoder_handles_fragmented_and_coalesced_frames(self):
        decoder = ControlFrameDecoder()
        self.assertEqual(decoder.feed(b"\x00\x00"), [])
        self.assertEqual(decoder.feed(b"\x00\x03abc\x00\x00\x00\x02de"), [b"abc", b"de"])

    def test_decoder_rejects_zero_and_oversize_lengths_before_allocation(self):
        decoder = ControlFrameDecoder(max_message=4)
        with self.assertRaises(ControlFrameError):
            decoder.feed(b"\x00\x00\x00\x00")
        with self.assertRaises(ControlFrameError):
            decoder.feed(b"\x00\x00\x00\x05")


class AudioDatagramTests(unittest.TestCase):
    def test_round_trip_preserves_fixed_header_and_pcm_bytes(self):
        packet = AudioDatagram(17, 0xFFFFFFFF, bytes(range(256)) * 3 + bytes(range(192)))
        encoded = encode_audio_datagram(packet)
        self.assertEqual(len(encoded), 968)
        self.assertEqual(encoded[:8], b"\x00\x00\x00\x11\xff\xff\xff\xff")
        decoded = decode_audio_datagram(encoded)
        self.assertEqual(decoded.stream_id, 17)
        self.assertEqual(decoded.sequence, 0xFFFFFFFF)
        self.assertEqual(decoded.pcm, packet.pcm)

    def test_rejects_wrong_size_and_zero_stream_id(self):
        with self.assertRaises(AudioDatagramError):
            decode_audio_datagram(bytes(967))
        with self.assertRaises(AudioDatagramError):
            encode_audio_datagram(AudioDatagram(0, 0, bytes(960)))


if __name__ == "__main__":
    unittest.main()
