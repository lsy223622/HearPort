from collections import deque
from dataclasses import dataclass

from tests.reference.wire_codec import AudioDatagram


UINT32_MODULUS = 1 << 32
UINT32_HALF_RANGE = 1 << 31
PCM_BYTES = 960


def is_newer(sequence: int, reference: int) -> bool:
    delta = (sequence - reference) & 0xFFFFFFFF
    return 0 < delta < UINT32_HALF_RANGE


@dataclass
class JitterStats:
    duplicate: int = 0
    late: int = 0
    wrong_stream: int = 0
    loss: int = 0
    overflow: int = 0


class JitterBuffer:
    def __init__(self, stream_id: int, capacity_packets: int, target_packets: int):
        if stream_id == 0:
            raise ValueError("stream_id must be non-zero")
        if not 1 <= target_packets <= capacity_packets:
            raise ValueError("target must fit in jitter capacity")
        self.stream_id = stream_id
        self.capacity_packets = capacity_packets
        self.target_packets = target_packets
        self.mode = "buffering"
        self.stats = JitterStats()
        self._packets: dict[int, AudioDatagram] = {}
        self._expected: int | None = None

    def insert(self, packet: AudioDatagram) -> str:
        if packet.stream_id != self.stream_id:
            self.stats.wrong_stream += 1
            return "wrong_stream"
        if self._expected is not None and packet.sequence != self._expected and not is_newer(
            packet.sequence, self._expected
        ):
            self.stats.late += 1
            return "late"
        if packet.sequence in self._packets:
            self.stats.duplicate += 1
            return "duplicate"
        if len(self._packets) >= self.capacity_packets:
            self.stats.overflow += 1
            return "overflow"
        self._packets[packet.sequence] = packet
        if self._expected is None:
            self._expected = packet.sequence
        if len(self._packets) >= self.target_packets:
            self.mode = "playing"
        return "accepted"

    def consume_next(self) -> AudioDatagram | None:
        if self.mode != "playing" or self._expected is None:
            return None
        packet = self._packets.pop(self._expected, None)
        if packet is None:
            return None
        self._expected = (self._expected + 1) & 0xFFFFFFFF
        return packet

    def conceal_missing(self) -> bytes:
        if self.mode != "playing" or self._expected is None:
            return bytes(PCM_BYTES)
        self._packets.pop(self._expected, None)
        self._expected = (self._expected + 1) & 0xFFFFFFFF
        self.stats.loss += 1
        return bytes(PCM_BYTES)

    def enter_silent_rebuffer(self) -> None:
        self._packets.clear()
        self._expected = None
        self.mode = "silent_rebuffer"

    def reset(self, stream_id: int) -> None:
        if stream_id == 0:
            raise ValueError("stream_id must be non-zero")
        self.stream_id = stream_id
        self._packets.clear()
        self._expected = None
        self.mode = "buffering"
        self.stats = JitterStats()


class RenderRingBuffer:
    def __init__(self, capacity_frames: int):
        if capacity_frames <= 0:
            raise ValueError("capacity must be positive")
        self.capacity_frames = capacity_frames
        self._frames = deque()
        self.stats = type(
            "RenderStats", (), {"overflow_frames": 0, "underflow_frames": 0}
        )()

    def write(self, frames: list[float]) -> int:
        accepted = min(len(frames), self.capacity_frames - len(self._frames))
        self._frames.extend(frames[:accepted])
        self.stats.overflow_frames += len(frames) - accepted
        return accepted

    def read(self, count: int) -> list[float]:
        take = min(count, len(self._frames))
        result = [self._frames.popleft() for _ in range(take)]
        self.stats.underflow_frames += count - take
        return result


class DriftController:
    def __init__(self, target_frames: int):
        if target_frames <= 0:
            raise ValueError("target must be positive")
        self.target_frames = target_frames
        self._filtered_error = 0.0
        self._last_ratio: float | None = None

    def update(self, fill_frames: int, valid_audio: bool, nominal_ratio: float) -> float:
        if not valid_audio:
            return nominal_ratio if self._last_ratio is None else self._last_ratio
        error = fill_frames - self.target_frames
        self._filtered_error = self._filtered_error * 0.95 + error * 0.05
        normalized = self._filtered_error / self.target_frames
        correction = max(-0.001, min(0.001, normalized * 0.001))
        self._last_ratio = nominal_ratio * (1.0 + correction)
        return self._last_ratio

    def freeze(self) -> None:
        pass

    def reset(self) -> None:
        self._filtered_error = 0.0
        self._last_ratio = None
