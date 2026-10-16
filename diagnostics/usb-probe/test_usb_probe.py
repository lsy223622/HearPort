import unittest
from usb_probe import FrameDecoder, encode_frame, run_session, DATA, PING, PONG, FINISH, SUMMARY, HELLO
import contextlib
import io
import json
import socket
import struct
import threading
import time

class USBProbeTests(unittest.TestCase):
    def test_fragmented_frames_match_shared_fixture(self):
        frame = encode_frame(DATA, 7, 123, b"123456789")
        self.assertEqual(frame.hex(), "48505531010100000000000700000009000000000000007bcbf4392600000000313233343536373839")
        decoder = FrameDecoder()
        result = []
        for byte in frame + encode_frame(PING, 8, 456):
            result.extend(decoder.append(bytes([byte])))
        self.assertEqual(result, [(DATA, 7, 123, b"123456789"), (PING, 8, 456, b"")])

    def test_corruption_and_oversized_header_are_rejected(self):
        frame = bytearray(encode_frame(DATA, 0, 0, b"abc"))
        frame[-1] ^= 1
        with self.assertRaises(ValueError): FrameDecoder().append(frame)
        frame = bytearray(encode_frame(DATA, 0, 0))
        frame[12:16] = (65537).to_bytes(4,"big")
        with self.assertRaises(ValueError): FrameDecoder().append(frame)
        frame = bytearray(encode_frame(DATA, 0, 0))
        frame[7] = 1
        with self.assertRaises(ValueError): FrameDecoder().append(frame)

    def test_duplex_session_checks_final_receiver_count(self):
        host, device = socket.socketpair()
        host.settimeout(2)
        device.settimeout(2)
        def peer():
            decoder = FrameDecoder()
            count = 0
            try:
                device.sendall(encode_frame(HELLO, 0, 0, b"{}"))
                while True:
                    data = device.recv(65536)
                    if not data: break
                    for kind, seq, at, payload in decoder.append(data):
                        if kind == DATA: count += 1
                        elif kind == PING:
                            now = time.perf_counter_ns()
                            response = struct.pack("!10Q", now, now, count, count * 992, 0,0,0,0,at,now)
                            device.sendall(encode_frame(PONG, seq, at, response))
                        elif kind == FINISH:
                            response = json.dumps(dict(received=count, crc_errors=0)).encode()
                            device.sendall(encode_frame(SUMMARY, 0, 0, response))
            finally: device.close()
        thread = threading.Thread(target=peer)
        thread.start()
        rows = []
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertTrue(run_session(host, .03, lambda event, **fields: rows.append((event, fields))))
        thread.join(timeout=3)
        result = next(row for event,row in rows if event == "session_result")
        self.assertGreater(result["sent"], 0)
        self.assertEqual(result["sent"], result["receiver"]["received"])
        self.assertIsNotNone(result["rtt_ms"]["95"])

if __name__ == "__main__": unittest.main()
