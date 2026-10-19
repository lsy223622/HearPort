"""Loopback QUIC peer for the native Network.framework transport test."""

import asyncio
import datetime
import logging
import pathlib
import tempfile
from usb_packet_bridge import usb_packet_bridge

from aioquic.asyncio import QuicConnectionProtocol, serve
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import HandshakeCompleted, StreamDataReceived, ConnectionTerminated
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID


class EchoProtocol(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # Match HearPort's single client-initiated bidirectional control stream.
        self._quic._local_max_streams_bidi.value = 1
        self._quic._local_max_streams_bidi.sent = 1
        self._quic._local_max_streams_uni.value = 0
        self._quic._local_max_streams_uni.sent = 0
        self.sent_audio = False
        self.reliable_requests = bytearray()
        self.reliable_generation = 0
        self.cycle_generation = 0

    def quic_event_received(self, event):
        if isinstance(event, HandshakeCompleted):
            print(f"handshake alpn={event.alpn_protocol} "
                  f"peer_datagram_limit={self._quic._remote_max_datagram_frame_size}", flush=True)
        elif isinstance(event, StreamDataReceived):
            print(f"stream={event.stream_id} bytes={len(event.data)} fin={event.end_stream}", flush=True)
            if not event.data:
                return
            self._quic.send_stream_data(event.stream_id, event.data, end_stream=False)
            self.reliable_requests.extend(event.data)
            for command, sequence, generation, kind, frames, payload in [
                (b"COMPRESSION_TEST_1", 0, 2, 6, 120, bytes([17]) * 480),
                (b"COMPRESSION_TEST_2", 24000, 4, 5, 480, bytes([161]) * 320),
                (b"COMPRESSION_TEST_3", 48000, 6, 0, 120, bytes(960)),
            ]:
                if command not in self.reliable_requests:
                    continue

                def timed_packet(packet_sequence, packet_payload):
                    return ((1).to_bytes(4, "big") + generation.to_bytes(4, "big") +
                            packet_sequence.to_bytes(4, "big") + frames.to_bytes(2, "big") +
                            kind.to_bytes(2, "big") + (1).to_bytes(8, "big") +
                            (packet_sequence * 120).to_bytes(8, "big") + packet_payload)

                packet = timed_packet(sequence, payload)
                if kind == 5:
                    stream = self._quic.get_next_available_stream_id(is_unidirectional=True)
                    preface = (1).to_bytes(4, "big") + generation.to_bytes(4, "big")
                    framed = len(packet).to_bytes(2, "big") + packet
                    following = b"".join(
                        len(extra).to_bytes(2, "big") + extra
                        for extra in [timed_packet(sequence + 4, bytes([162]) * 320),
                                      timed_packet(sequence + 8, bytes([163]) * 320)])
                    chunks = [preface[:3], preface[3:] + framed[:1],
                              framed[1:15], framed[15:] + following]
                    self._quic.send_stream_data(stream, chunks[0], end_stream=False)
                    self.transmit()

                    def send_chunk(chunk, final):
                        self._quic.send_stream_data(stream, chunk, end_stream=final)
                        self.transmit()

                    loop = asyncio.get_running_loop()
                    for index, chunk in enumerate(chunks[1:], 1):
                        loop.call_later(index * 0.025, send_chunk, chunk, index == 3)
                else:
                    self._quic.send_datagram_frame(packet)
                self.sent_audio = True
                self.reliable_requests.clear()
                break
            for command, sequence, generation, reliable in [
                (b"MUSIC_TEST_1", 0, 2, False),
                (b"MUSIC_TEST_2", 96000, 4, True),
                (b"MUSIC_TEST_3", 288000, 6, False),
            ]:
                if command not in self.reliable_requests:
                    continue
                packet = (b"\x00\x00\x00\x01" + generation.to_bytes(4, "big") +
                          sequence.to_bytes(4, "big") + b"\x00\x78\x00\x00" +
                          (1).to_bytes(8, "big") + (sequence * 120).to_bytes(8, "big") + bytes(960))
                if reliable:
                    stream = self._quic.get_next_available_stream_id(is_unidirectional=True)
                    preface = (1).to_bytes(4, "big") + generation.to_bytes(4, "big")
                    self._quic.send_stream_data(stream, preface + packet,
                                                end_stream=True)
                else:
                    self._quic.send_datagram_frame(packet)
                self.sent_audio = True
                self.reliable_requests.clear()
                break
            if b"NETWORK_PROBE" in self.reliable_requests:
                probe_stream = self._quic.get_next_available_stream_id(is_unidirectional=True)
                preface = (1).to_bytes(4, "big") + (1).to_bytes(4, "big")
                packet = (1).to_bytes(4, "big") + (1).to_bytes(4, "big") + bytes(480)
                self._quic.send_stream_data(probe_stream, preface[:3], end_stream=False)
                self._quic.send_stream_data(probe_stream,
                                            preface[3:] + len(packet).to_bytes(2, "big") + packet,
                                            end_stream=True)
                self.reliable_requests.clear()
            if b"RELIABLE_CYCLE_" in self.reliable_requests and self.cycle_generation < 10:
                self.cycle_generation += 1
                audio_stream = self._quic.get_next_available_stream_id(
                    is_unidirectional=True)
                preface = ((1).to_bytes(4, "big") +
                           self.cycle_generation.to_bytes(4, "big"))
                packet = ((1).to_bytes(4, "big") +
                          (self.cycle_generation - 1).to_bytes(4, "big") + bytes(960))
                self._quic.send_stream_data(audio_stream, preface + packet,
                                            end_stream=True)
                self.reliable_requests.clear()
            if b"RELIABLE_ABORT_1" in self.reliable_requests:
                audio_stream = self._quic.get_next_available_stream_id(
                    is_unidirectional=True)
                preface = (1).to_bytes(4, "big") + (1).to_bytes(4, "big")
                packet = (1).to_bytes(4, "big") + (0).to_bytes(4, "big") + bytes(960)
                self._quic.send_stream_data(audio_stream, preface + packet + packet[:1])
                self.reliable_requests.clear()
                self.transmit()

                def replace_audio_stream():
                    self._quic.reset_stream(audio_stream, error_code=0)
                    next_stream = self._quic.get_next_available_stream_id(
                        is_unidirectional=True)
                    next_preface = (1).to_bytes(4, "big") + (2).to_bytes(4, "big")
                    next_packet = ((1).to_bytes(4, "big") +
                                   (1).to_bytes(4, "big") + bytes(960))
                    self._quic.send_stream_data(next_stream, next_preface + next_packet,
                                                end_stream=True)
                    self.transmit()

                asyncio.get_running_loop().call_later(0.1, replace_audio_stream)
            marker = f"RELIABLE_{self.reliable_generation + 1}".encode()
            if marker in self.reliable_requests and self.reliable_generation < 2:
                self.reliable_generation += 1
                audio_stream = self._quic.get_next_available_stream_id(
                    is_unidirectional=True)
                preface = (1).to_bytes(4, "big") + self.reliable_generation.to_bytes(4, "big")
                packet = ((1).to_bytes(4, "big") +
                          (self.reliable_generation - 1).to_bytes(4, "big") + bytes(960))
                self._quic.send_stream_data(audio_stream, preface[:3], end_stream=False)
                self._quic.send_stream_data(audio_stream, preface[3:] + packet,
                                            end_stream=True)
                self.reliable_requests.clear()
            if not self.sent_audio:
                self.sent_audio = True
                self._quic.send_datagram_frame(b"\x00\x00\x00\x01" + bytes(964))
            self.transmit()
        elif isinstance(event, ConnectionTerminated):
            print(f"closed code={event.error_code} reason={event.reason_phrase}", flush=True)



async def main():
    bridge = asyncio.create_task(usb_packet_bridge())
    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        key = ec.generate_private_key(ec.SECP256R1())
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "localhost")])
        now = datetime.datetime.now(datetime.timezone.utc)
        cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
                .public_key(key.public_key()).serial_number(x509.random_serial_number())
                .not_valid_before(now - datetime.timedelta(minutes=1))
                .not_valid_after(now + datetime.timedelta(days=1))
                .sign(key, hashes.SHA256()))
        (root / "cert.pem").write_bytes(cert.public_bytes(serialization.Encoding.PEM))
        (root / "key.pem").write_bytes(key.private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption()))
        configuration = QuicConfiguration(
            is_client=False, alpn_protocols=["hearport/1"],
            max_datagram_frame_size=65535, idle_timeout=10)
        configuration.load_cert_chain(root / "cert.pem", root / "key.pem")
        server = await serve("127.0.0.1", 44330, configuration=configuration,
                             create_protocol=EchoProtocol)
        print("quic_test_server_ready", flush=True)
        try:
            await asyncio.Future()
        finally:
            server.close()


if __name__ == "__main__":
    logging.basicConfig(level=logging.DEBUG)
    asyncio.run(main())
