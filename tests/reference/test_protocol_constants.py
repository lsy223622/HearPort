import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ProtocolConstantsTests(unittest.TestCase):
    def test_v1_wire_constants_match_normative_profile(self):
        constants_path = ROOT / "protocol" / "protocol_constants.json"
        with constants_path.open(encoding="utf-8") as handle:
            constants = json.load(handle)

        self.assertEqual(constants["alpn"], "hearport/1")
        self.assertEqual(constants["default_udp_port"], 52137)
        self.assertEqual(constants["sample_rate_hz"], 48000)
        self.assertEqual(constants["channels"], 2)
        self.assertEqual(constants["sample_format"], "float32le")
        self.assertEqual(constants["frames_per_audio_datagram"], 120)
        self.assertEqual(constants["pcm_bytes_per_audio_datagram"], 960)
        self.assertEqual(constants["audio_application_datagram_bytes"], 968)
        self.assertEqual(constants["control_message_max_bytes"], 65536)

    def test_audio_layout_is_arithmetically_consistent(self):
        constants_path = ROOT / "protocol" / "protocol_constants.json"
        with constants_path.open(encoding="utf-8") as handle:
            constants = json.load(handle)

        pcm_bytes = (
            constants["frames_per_audio_datagram"]
            * constants["channels"]
            * constants["bytes_per_sample"]
        )
        self.assertEqual(pcm_bytes, constants["pcm_bytes_per_audio_datagram"])
        self.assertEqual(
            8 + pcm_bytes, constants["audio_application_datagram_bytes"]
        )


if __name__ == "__main__":
    unittest.main()
