"""Small, deterministic reference helpers for HearPort Security v1."""

from __future__ import annotations

import hashlib
import hmac
import secrets
from typing import Optional


P256_ORDER = int(
    "FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551", 16
)
PIN_DOMAIN = b"HearPort-SPAKE2-v1"
AUTH_DOMAIN = b"HearPort-Auth-v1"
WINDOWS_IDENTITY_PREFIX = b"HearPort-Windows-v1"
RECEIVER_IDENTITY = b"HearPort-Receiver-v1"


def _pin_bytes(pin: str | bytes) -> bytes:
    if isinstance(pin, str):
        try:
            return pin.encode("ascii")
        except UnicodeEncodeError:
            return b""
    return bytes(pin)


def validate_pin(pin: str | bytes) -> bool:
    value = _pin_bytes(pin)
    return len(value) == 6 and all(0x30 <= byte <= 0x39 for byte in value)


def pin_to_scalar(pin: str | bytes) -> bytes:
    value = _pin_bytes(pin)
    if not validate_pin(value):
        raise ValueError("PIN must contain exactly six ASCII decimal digits")
    digest = hashlib.sha256(PIN_DOMAIN + b"\x00" + value).digest()
    scalar = (int.from_bytes(digest, "big") % (P256_ORDER - 1)) + 1
    return scalar.to_bytes(32, "big")


def sha256_spki(der_subject_public_key_info: bytes) -> bytes:
    if not der_subject_public_key_info:
        raise ValueError("SPKI must not be empty")
    return hashlib.sha256(der_subject_public_key_info).digest()


def build_identity_a(windows_spki_sha256: bytes) -> bytes:
    if len(windows_spki_sha256) != 32:
        raise ValueError("Windows SPKI hash must be 32 bytes")
    return WINDOWS_IDENTITY_PREFIX + b"\x00" + bytes(windows_spki_sha256)


def build_identity_b() -> bytes:
    return RECEIVER_IDENTITY


def remembered_auth_mac(
    pair_secret: bytes, nonce: bytes, windows_spki_sha256: bytes
) -> bytes:
    if len(pair_secret) != 32:
        raise ValueError("pair_secret must be 32 bytes")
    if len(nonce) != 32:
        raise ValueError("nonce must be 32 bytes")
    if len(windows_spki_sha256) != 32:
        raise ValueError("Windows SPKI hash must be 32 bytes")
    return hmac.new(
        bytes(pair_secret),
        AUTH_DOMAIN + bytes(nonce) + bytes(windows_spki_sha256),
        hashlib.sha256,
    ).digest()


def constant_time_equal(left: bytes, right: bytes) -> bool:
    return hmac.compare_digest(bytes(left), bytes(right))


class PairingWindow:
    def __init__(self, duration_seconds: float = 120.0, maximum_failures: int = 5):
        if duration_seconds <= 0 or maximum_failures <= 0:
            raise ValueError("pairing window bounds must be positive")
        self.duration_seconds = float(duration_seconds)
        self.maximum_failures = int(maximum_failures)
        self._opened_at: Optional[float] = None
        self._failures = 0

    @property
    def failures(self) -> int:
        return self._failures

    def open(self, now: float) -> bool:
        self._opened_at = float(now)
        self._failures = 0
        return True

    def close(self) -> None:
        self._opened_at = None

    def is_open(self, now: float) -> bool:
        if self._opened_at is None:
            return False
        if float(now) - self._opened_at >= self.duration_seconds:
            self.close()
            return False
        return self._failures < self.maximum_failures

    def record_failure(self, now: float) -> bool:
        if not self.is_open(now):
            return False
        self._failures += 1
        if self._failures >= self.maximum_failures:
            self.close()
            return False
        return True


class RememberedAuthSession:
    def __init__(self, peer_id: bytes, pair_secret: bytes, windows_spki_sha256: bytes):
        if len(peer_id) != 16 or len(pair_secret) != 32 or len(windows_spki_sha256) != 32:
            raise ValueError("invalid remembered credential lengths")
        self.peer_id = bytes(peer_id)
        self.pair_secret = bytes(pair_secret)
        self.windows_spki_sha256 = bytes(windows_spki_sha256)
        self._pending_nonce: Optional[bytes] = None

    def issue_challenge(self, nonce: bytes | None = None) -> bytes:
        candidate = secrets.token_bytes(32) if nonce is None else bytes(nonce)
        if len(candidate) != 32:
            raise ValueError("nonce must be 32 bytes")
        self._pending_nonce = candidate
        return candidate

    def verify(self, peer_id: bytes, mac: bytes) -> bool:
        nonce = self._pending_nonce
        self._pending_nonce = None
        if nonce is None or not constant_time_equal(peer_id, self.peer_id):
            return False
        expected = remembered_auth_mac(self.pair_secret, nonce, self.windows_spki_sha256)
        return constant_time_equal(mac, expected)

    def trust_material_after_pairing(self, success: bool, remember: bool):
        if not success or not remember:
            return None
        return {"peer_id": bytes(self.peer_id), "pair_secret": bytes(self.pair_secret)}
