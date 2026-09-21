import unittest

from tests.reference.session_state import ProtocolError, SessionState
from tests.reference.wire_codec import AudioDatagram


class SessionStateTests(unittest.TestCase):
    def test_first_message_requires_valid_connect_request(self):
        session = SessionState()
        with self.assertRaises(ProtocolError):
            session.receive({"type": "start_stream", "stream_id": 7})

        session = SessionState()
        with self.assertRaises(ProtocolError):
            session.receive({"type": "connect_request", "auth_mode": "UNSPECIFIED", "peer_id": b""})

        session = SessionState()
        session.receive({"type": "connect_request", "auth_mode": "PAIR", "peer_id": b""})
        self.assertEqual(session.phase, "authenticating")

        session = SessionState()
        with self.assertRaises(ProtocolError):
            session.receive({"type": "connect_request", "auth_mode": "REMEMBERED", "peer_id": b"short"})

    def test_start_stream_ack_gates_audio(self):
        session = SessionState()
        session.receive({"type": "connect_request", "auth_mode": "ONE_TIME", "peer_id": b""})
        session.mark_authenticated()
        session.begin_stream(7)
        self.assertEqual(session.phase, "pending_stream")
        audio = AudioDatagram(7, 0, bytes(960))
        self.assertEqual(session.accept_audio(audio), "pending_audio_discarded")
        self.assertEqual(session.ack_written(7), "active")
        self.assertEqual(session.accept_audio(audio), "accepted")

    def test_mismatched_ack_and_old_stream_are_rejected_without_closing(self):
        session = SessionState()
        session.receive({"type": "connect_request", "auth_mode": "ONE_TIME", "peer_id": b""})
        session.mark_authenticated()
        session.begin_stream(7)
        self.assertEqual(session.ack_written(8), "protocol_error")
        self.assertEqual(session.phase, "pending_stream")
        session.ack_written(7)
        session.begin_stream(9)
        session.ack_written(9)
        self.assertEqual(session.accept_audio(AudioDatagram(7, 0, bytes(960))), "old_stream_discarded")

    def test_capture_reset_replaces_stream_and_clears_pending_state(self):
        session = SessionState()
        session.receive({"type": "connect_request", "auth_mode": "ONE_TIME", "peer_id": b""})
        session.mark_authenticated()
        session.begin_stream(7)
        session.ack_written(7)
        session.reset_stream(8)
        self.assertEqual(session.phase, "pending_stream")
        self.assertEqual(session.active_stream_id, None)
        self.assertEqual(session.pending_stream_id, 8)


if __name__ == "__main__":
    unittest.main()
