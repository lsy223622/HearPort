import hashlib
import hmac
import json
import pathlib
import unittest

from tests.reference.security import (
    PairingWindow,
    RememberedAuthSession,
    build_identity_a,
    build_identity_b,
    constant_time_equal,
    remembered_auth_mac,
    sha256_spki,
    validate_pin,
    pin_to_scalar,
)


FIXTURES = pathlib.Path(__file__).parents[1] / "fixtures" / "security_vectors.json"


class SecurityVectorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.vectors = json.loads(FIXTURES.read_text(encoding="utf-8"))

    def test_pin_format_and_leading_zero_vector(self):
        vector = self.vectors["pin_scalar"]
        self.assertTrue(validate_pin(vector["pin"]))
        self.assertEqual(pin_to_scalar(vector["pin"]).hex(), vector["scalar_hex"])
        self.assertTrue(validate_pin("000001"))
        for invalid in ("12345", "1234567", "12a456", "１２３４５６", b"123456\x00"):
            self.assertFalse(validate_pin(invalid))

    def test_identity_and_remembered_auth_vectors(self):
        vector = self.vectors["remembered_auth"]
        spki = bytes.fromhex(vector["spki_der_hex"])
        spki_hash = sha256_spki(spki)
        self.assertEqual(spki_hash.hex(), vector["spki_sha256_hex"])
        self.assertEqual(build_identity_a(spki_hash), bytes.fromhex(vector["identity_a_hex"]))
        self.assertEqual(build_identity_b(), bytes.fromhex(vector["identity_b_hex"]))
        mac = remembered_auth_mac(
            bytes.fromhex(vector["pair_secret_hex"]),
            bytes.fromhex(vector["nonce_hex"]),
            spki_hash,
        )
        self.assertEqual(mac.hex(), vector["mac_hex"])
        self.assertTrue(constant_time_equal(mac, bytes.fromhex(vector["mac_hex"])))
        self.assertFalse(constant_time_equal(mac, b"\x00" * len(mac)))

    def test_remembered_auth_consumes_nonce_on_success_and_failure(self):
        vector = self.vectors["remembered_auth"]
        session = RememberedAuthSession(
            peer_id=bytes.fromhex(vector["peer_id_hex"]),
            pair_secret=bytes.fromhex(vector["pair_secret_hex"]),
            windows_spki_sha256=bytes.fromhex(vector["spki_sha256_hex"]),
        )
        nonce = bytes.fromhex(vector["nonce_hex"])
        session.issue_challenge(nonce)
        peer_id = bytes.fromhex(vector["peer_id_hex"])
        mac = bytes.fromhex(vector["mac_hex"])
        self.assertTrue(session.verify(peer_id, mac))
        self.assertFalse(session.verify(peer_id, mac))
        session.issue_challenge(nonce)
        self.assertFalse(session.verify(b"\x00" * 16, mac))
        self.assertFalse(session.verify(peer_id, mac))

    def test_pairing_window_is_shared_and_closes_on_fifth_failure(self):
        window = PairingWindow(duration_seconds=120, maximum_failures=5)
        self.assertTrue(window.open(now=100.0))
        self.assertTrue(window.is_open(now=100.0))
        for attempt in range(1, 5):
            self.assertTrue(window.record_failure(now=100.0 + attempt))
            self.assertTrue(window.is_open(now=100.0 + attempt))
        self.assertFalse(window.record_failure(now=105.0))
        self.assertFalse(window.is_open(now=105.0))
        self.assertFalse(window.record_failure(now=106.0))
        self.assertTrue(window.open(now=200.0))
        self.assertTrue(window.is_open(now=200.0))

    def test_failed_pairing_does_not_create_trust_material(self):
        vector = self.vectors["remembered_auth"]
        session = RememberedAuthSession(
            peer_id=bytes.fromhex(vector["peer_id_hex"]),
            pair_secret=bytes.fromhex(vector["pair_secret_hex"]),
            windows_spki_sha256=bytes.fromhex(vector["spki_sha256_hex"]),
        )
        self.assertIsNone(session.trust_material_after_pairing(success=False, remember=True))
        self.assertEqual(
            session.trust_material_after_pairing(success=True, remember=True)["peer_id"],
            bytes.fromhex(vector["peer_id_hex"]),
        )


if __name__ == "__main__":
    unittest.main()
