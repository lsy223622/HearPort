from dataclasses import dataclass
import struct


CONTROL_HEADER_BYTES = 4
CONTROL_MESSAGE_MAX_BYTES = 65536
AUDIO_HEADER_BYTES = 8
AUDIO_PCM_BYTES = 960
AUDIO_DATAGRAM_BYTES = AUDIO_HEADER_BYTES + AUDIO_PCM_BYTES


class ControlFrameError(ValueError):
    pass


class AudioDatagramError(ValueError):
    pass


def encode_control_frame(payload: bytes) -> bytes:
    if not isinstance(payload, bytes):
        payload = bytes(payload)
    if not 1 <= len(payload) <= CONTROL_MESSAGE_MAX_BYTES:
        raise ControlFrameError("control message length is outside v1 bounds")
    return struct.pack(">I", len(payload)) + payload


class ControlFrameDecoder:
    def __init__(self, max_message: int = 65536):
        if not 1 <= max_message <= CONTROL_MESSAGE_MAX_BYTES:
            raise ValueError("max_message is outside v1 bounds")
        self._max_message = max_message
        self._buffer = bytearray()

    def feed(self, data: bytes) -> list[bytes]:
        self._buffer.extend(data)
        messages: list[bytes] = []
        while True:
            if len(self._buffer) < CONTROL_HEADER_BYTES:
                return messages
            length = struct.unpack(">I", self._buffer[:CONTROL_HEADER_BYTES])[0]
            if not 1 <= length <= self._max_message:
                self._buffer.clear()
                raise ControlFrameError("control message length is outside v1 bounds")
            frame_end = CONTROL_HEADER_BYTES + length
            if len(self._buffer) < frame_end:
                return messages
            messages.append(bytes(self._buffer[CONTROL_HEADER_BYTES:frame_end]))
            del self._buffer[:frame_end]


@dataclass(frozen=True)
class AudioDatagram:
    stream_id: int
    sequence: int
    pcm: bytes


def encode_audio_datagram(packet: AudioDatagram) -> bytes:
    if not 1 <= packet.stream_id <= 0xFFFFFFFF:
        raise AudioDatagramError("stream_id must be non-zero")
    if not 0 <= packet.sequence <= 0xFFFFFFFF:
        raise AudioDatagramError("sequence must fit uint32")
    if len(packet.pcm) != AUDIO_PCM_BYTES:
        raise AudioDatagramError("PCM payload must contain exactly 960 bytes")
    return struct.pack(">II", packet.stream_id, packet.sequence) + packet.pcm


def decode_audio_datagram(payload: bytes) -> AudioDatagram:
    if len(payload) != AUDIO_DATAGRAM_BYTES:
        raise AudioDatagramError("AUDIO datagram must contain exactly 968 bytes")
    stream_id, sequence = struct.unpack(">II", payload[:AUDIO_HEADER_BYTES])
    if stream_id == 0:
        raise AudioDatagramError("stream_id must be non-zero")
    return AudioDatagram(stream_id, sequence, payload[AUDIO_HEADER_BYTES:])
