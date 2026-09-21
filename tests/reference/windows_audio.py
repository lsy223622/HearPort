import struct

from tests.reference.wire_codec import AudioDatagram


CANONICAL_RATE = 48000
FRAMES_PER_PACKET = 120


class PcmNormalizer:
    def __init__(self, sample_rate_hz: int, channels: int, sample_format: str):
        if sample_rate_hz <= 0 or channels <= 0:
            raise ValueError("invalid source format")
        if sample_format not in {"float32le", "int16le", "int24le", "int32le"}:
            raise ValueError("unsupported source format")
        self.sample_rate_hz = sample_rate_hz
        self.channels = channels
        self.sample_format = sample_format

    def _bytes_per_sample(self) -> int:
        return {"float32le": 4, "int16le": 2, "int24le": 3, "int32le": 4}[self.sample_format]

    def _decode_sample(self, raw: bytes) -> float:
        if self.sample_format == "float32le":
            return struct.unpack("<f", raw)[0]
        if self.sample_format == "int16le":
            return struct.unpack("<h", raw)[0] / 32768.0
        if self.sample_format == "int32le":
            return struct.unpack("<i", raw)[0] / 2147483648.0
        value = raw[0] | (raw[1] << 8) | (raw[2] << 16)
        if value & 0x800000:
            value -= 1 << 24
        return value / 8388608.0

    def convert(self, raw: bytes) -> list[float]:
        bytes_per_frame = self.channels * self._bytes_per_sample()
        if len(raw) % bytes_per_frame:
            raise ValueError("source bytes do not contain complete frames")
        source_frames: list[list[float]] = []
        bytes_per_sample = self._bytes_per_sample()
        for offset in range(0, len(raw), bytes_per_frame):
            channels = [
                self._decode_sample(raw[offset + index * bytes_per_sample : offset + (index + 1) * bytes_per_sample])
                for index in range(self.channels)
            ]
            if self.channels == 1:
                source_frames.append([channels[0], channels[0]])
            else:
                source_frames.append([channels[0], channels[1]])
        if self.sample_rate_hz == CANONICAL_RATE or not source_frames:
            return [value for frame in source_frames for value in frame]

        output_frames = round(len(source_frames) * CANONICAL_RATE / self.sample_rate_hz)
        output: list[float] = []
        for output_index in range(output_frames):
            position = output_index * self.sample_rate_hz / CANONICAL_RATE
            left_index = min(int(position), len(source_frames) - 1)
            right_index = min(left_index + 1, len(source_frames) - 1)
            fraction = position - int(position)
            for channel in range(2):
                value = source_frames[left_index][channel] * (1.0 - fraction)
                value += source_frames[right_index][channel] * fraction
                output.append(value)
        return output


class AudioPacketizer:
    def __init__(self, stream_id: int):
        if stream_id == 0:
            raise ValueError("stream_id must be non-zero")
        self.stream_id = stream_id
        self.sequence = 0
        self._buffer: list[float] = []

    @property
    def buffered_frames(self) -> int:
        return len(self._buffer) // 2

    def push(self, interleaved_stereo: list[float]) -> list[AudioDatagram]:
        if len(interleaved_stereo) % 2:
            raise ValueError("stereo input must contain complete frames")
        self._buffer.extend(interleaved_stereo)
        packets: list[AudioDatagram] = []
        samples_per_packet = FRAMES_PER_PACKET * 2
        while len(self._buffer) >= samples_per_packet:
            samples = self._buffer[:samples_per_packet]
            del self._buffer[:samples_per_packet]
            pcm = b"".join(struct.pack("<f", value) for value in samples)
            packets.append(AudioDatagram(self.stream_id, self.sequence, pcm))
            self.sequence = (self.sequence + 1) & 0xFFFFFFFF
        return packets
