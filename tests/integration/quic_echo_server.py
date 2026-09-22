"""Loopback QUIC peer for the native Network.framework transport test."""

import asyncio
import datetime
import logging
import pathlib
import tempfile

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

    def quic_event_received(self, event):
        if isinstance(event, HandshakeCompleted):
            print(f"handshake alpn={event.alpn_protocol} "
                  f"peer_datagram_limit={self._quic._remote_max_datagram_frame_size}", flush=True)
        elif isinstance(event, StreamDataReceived):
            print(f"stream={event.stream_id} bytes={len(event.data)} fin={event.end_stream}", flush=True)
            if not event.data:
                return
            self._quic.send_stream_data(event.stream_id, event.data, end_stream=False)
            if not self.sent_audio:
                self.sent_audio = True
                self._quic.send_datagram_frame(b"\x00\x00\x00\x01" + bytes(964))
            self.transmit()
        elif isinstance(event, ConnectionTerminated):
            print(f"closed code={event.error_code} reason={event.reason_phrase}", flush=True)



async def main():
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
