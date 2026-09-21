import unittest

from tests.reference.control_messages import (
    AuthMode,
    ControlEnvelope,
    ControlMessageError,
    MessageType,
    decode_control_envelope,
    encode_control_envelope,
)


class ControlMessageTests(unittest.TestCase):
    def test_connect_request_vector_matches_proto_field_numbers(self):
        message = ControlEnvelope(MessageType.CONNECT_REQUEST, auth_mode=AuthMode.PAIR)
        encoded = encode_control_envelope(message)
        self.assertEqual(encoded, bytes.fromhex("0a020802"))
        self.assertEqual(decode_control_envelope(encoded), message)

    def test_start_stream_vector_uses_uint32_varint_inside_oneof(self):
        message = ControlEnvelope(MessageType.START_STREAM_ACK, stream_id=7)
        encoded = encode_control_envelope(message)
        self.assertEqual(encoded, bytes.fromhex("fa01020807"))
        self.assertEqual(decode_control_envelope(encoded), message)

    def test_auth_response_and_credentials_are_length_delimited(self):
        message = ControlEnvelope(
            MessageType.AUTH_RESPONSE,
            bytes1=bytes(range(16)),
            bytes2=bytes(range(32)),
        )
        self.assertEqual(decode_control_envelope(encode_control_envelope(message)), message)

    def test_decoder_rejects_unknown_duplicate_or_malformed_fields(self):
        with self.assertRaises(ControlMessageError):
            decode_control_envelope(bytes.fromhex("12020801"))
        with self.assertRaises(ControlMessageError):
            decode_control_envelope(bytes.fromhex("0a0408020802"))
        with self.assertRaises(ControlMessageError):
            decode_control_envelope(bytes.fromhex("f201020800"))


if __name__ == "__main__":
    unittest.main()
