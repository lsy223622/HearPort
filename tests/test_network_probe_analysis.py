import json
import tempfile
import unittest
from pathlib import Path

from diagnostics.analyze_network_probe import analyze, simulate_buffer


class NetworkProbeAnalysisTests(unittest.TestCase):
    def test_short_drift_cannot_replace_missing_packets(self):
        arrivals = [i * 2_500_000 for i in range(400)
                    if not 80 <= i < 108]
        fixed = simulate_buffer(arrivals, 400, 1, 50, False)
        adaptive = simulate_buffer(arrivals, 400, 1, 50, True)
        self.assertGreater(fixed["empty"], 0)
        self.assertGreater(adaptive["empty"], 0)
        self.assertGreater(adaptive["slow_ticks"], 0)
        self.assertLess(adaptive["ticks"], fixed["ticks"])

    def test_joins_receiver_missing_to_sender_stage(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = root / "report.txt"
            sender = root / "sender.jsonl"
            log = root / "sender.log"
            report.write_text(
                "stream_id=7\nnetwork_probe_rounds_v2\n"
                "round\ttransport\trepeat\tvariant\tseconds\tpayload_bytes\t"
                "packets_per_second\tburst_packets\tfirst_sequence\tplanned\n"
                "1\treliable_stream\t1\t4\t1\t488\t100\t1\t0\t100\n"
                "network_probe_trace_v1\n"
                "received_at_ns\tstream_id\tsequence\tpayload_bytes\n" +
                "".join(f"{i * 10_000_000}\t7\t{i}\t488\n" for i in range(98)) +
                "app_diagnostics_v1\n", encoding="utf-8")
            with sender.open("w", encoding="utf-8") as output:
                for i in range(100):
                    output.write(json.dumps({
                        "type": "packet", "sequence": i,
                        "send_accepted": i != 98,
                        "send_state": "lost_discarded" if i == 99 else "unknown"
                    }) + "\n")
            log.write_text("network_probe_round_end round=1 stream_id=7 "
                           "reject_pending_limit=1 pending_peak=128\n",
                           encoding="utf-8")
            result = next(analyze(report, sender, 100, log))
            self.assertEqual(result["missing_after_sender_rejection"], 1)
            self.assertEqual(result["missing_after_accepted_by_send_state"],
                             {"lost_discarded": 1})
            self.assertEqual(result["sender_round"]["reject_pending_limit"], 1)


if __name__ == "__main__":
    unittest.main()
