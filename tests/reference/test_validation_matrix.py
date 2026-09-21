import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MATRIX = ROOT / "docs" / "validation-matrix.md"
ALLOWED_EVIDENCE = {"automated", "native-build", "real-device", "network-soak", "not-available"}
REQUIRED_ROWS = {
    "protocol-control",
    "protocol-audio",
    "session-gating",
    "windows-capture",
    "windows-quic",
    "ios-quic",
    "ios-audio",
    "security-pairing",
    "security-remembered",
    "diagnostics",
    "network-impairment",
    "clock-drift",
    "foreground-soak",
    "silent-playback",
    "background-lock-screen",
    "route-interruption",
    "capture-reset",
}


class ValidationMatrixTests(unittest.TestCase):
    def test_matrix_covers_requirements_with_explicit_evidence_class(self):
        text = MATRIX.read_text(encoding="utf-8")
        rows = {}
        for line in text.splitlines():
            if not line.startswith("|") or line.startswith("|---"):
                continue
            cells = [cell.strip() for cell in line.strip("|").split("|")]
            if len(cells) < 5 or cells[0] == "ID":
                continue
            rows[cells[0]] = cells

        self.assertEqual(REQUIRED_ROWS, set(rows))
        for row_id, cells in rows.items():
            evidence_type = cells[2]
            evidence = cells[3].lower()
            self.assertIn(evidence_type, ALLOWED_EVIDENCE, row_id)
            self.assertTrue(cells[4], row_id)
            if evidence_type == "real-device":
                self.assertNotRegex(evidence, r"python|fixture|reference test")
            if evidence_type == "network-soak":
                self.assertNotRegex(evidence, r"unit test|fixture|reference test")

    def test_matrix_does_not_claim_unavailable_native_or_device_evidence(self):
        text = MATRIX.read_text(encoding="utf-8").lower()
        self.assertNotIn("native build: passed", text)
        self.assertNotIn("real device: passed", text)


if __name__ == "__main__":
    unittest.main()
