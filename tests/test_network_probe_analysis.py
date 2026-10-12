import json
import tempfile
import unittest
from pathlib import Path

from diagnostics import analyze_network_probe as probe
from diagnostics.analyze_network_probe import analyze, simulate_buffer


class NetworkProbeAnalysisTests(unittest.TestCase):
    def test_missing_first_burst_positions_do_not_shift_playout_deadlines(self):
        sender = {i: {"captured_at_ns": (i // 8) * 20_000_000,
                      "send_at_ns": (i // 8) * 20_000_000} for i in range(40)}
        arrivals = {i: sender[i]["send_at_ns"] for i in range(7, 40)}
        arrivals[8] += 90_000_000
        for recorded_sender in (sender, {i: row for i, row in sender.items() if i != 0}):
            result = probe.simulate_playout(arrivals, recorded_sender, 0, 40, 400, 100,
                                             False, burst_packets=8)
            self.assertEqual(result["concealed_late"], 0)

    def test_playout_preserves_missing_positions_and_counts_late_packets(self):
        sender = {i: {"captured_at_ns": i * 10_000_000, "send_at_ns": i * 10_000_000}
                  for i in range(100)}
        arrivals = {i: i * 10_000_000 + 40_000_000 for i in range(100) if i != 20}
        arrivals[30] += 200_000_000
        result = probe.simulate_playout(arrivals, sender, 0, 100, 100, 100, False)
        self.assertEqual(result["concealed_missing"], 1)
        self.assertEqual(result["concealed_late"], 1)
        self.assertEqual(result["played"], 98)
        self.assertAlmostEqual(result["playout_delay_ms"]["max"], 100)
        adaptive = probe.simulate_playout(arrivals, sender, 0, 100, 100, 100, True)
        self.assertEqual(adaptive["concealed_missing"], 1)

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
                "stream_id=7\nnetwork_probe_rounds_v3\n"
                "round\ttransport\trepeat\tvariant\tseconds\tpayload_bytes\t"
                "packets_per_second\tburst_packets\tfirst_sequence\tplanned\n"
                "1\treliable_stream\t1\t4\t1\t488\t100\t1\t0\t100\n"
                "network_probe_trace_v2\n"
                "received_at_ns\tstream_id\tsequence\tpayload_bytes\trecorded_at_ns\t"
                "callback_bytes\tcallback_packets\n" +
                "".join(f"{i * 10_000_000}\t7\t{i}\t488\t{i * 10_000_000 + 25000}\t488\t1\n"
                        for i in range(98)) +
                "network_probe_heartbeat_v1\nat_ns\tscheduled_at_ns\n500000000\t480000000\n" +
                "app_diagnostics_v1\n", encoding="utf-8")
            with sender.open("w", encoding="utf-8") as output:
                for i in range(100):
                    output.write(json.dumps({
                        "type": "packet", "sequence": i,
                        "captured_at_ns": i * 10_000_000, "send_at_ns": i * 10_000_000,
                        "send_accepted": i != 98,
                        "send_status": "pending_limit" if i == 98 else "accepted",
                        "pending_reliable_sends": 128 if i == 98 else 1,
                        "send_state": "lost_discarded" if i == 99 else "unknown"
                    }) + "\n")
            log.write_text("network_probe_round_end round=1 stream_id=7 "
                           "reject_pending_limit=1 pending_peak=128\n"
                           "network_probe_transport at_ns=50000000 query_status=0 rtt_us=123\n",
                           encoding="utf-8")
            result = next(analyze(report, sender, 100, log))
            self.assertEqual(result["missing_after_sender_rejection"], 1)
            self.assertEqual(result["missing_after_accepted_by_send_state"],
                             {"lost_discarded": 1})
            self.assertEqual(result["sender_round"]["reject_pending_limit"], 1)
            self.assertEqual(result["sender_pending_peak"], 128)
            self.assertEqual(result["sender_rejection_reasons"], {"pending_limit": 1})
            self.assertEqual(result["receiver_processing_ms"]["max"], .025)
            self.assertEqual(result["receiver_heartbeat_lateness_ms"]["max"], 20)
            self.assertEqual(result["transport_samples"][0]["rtt_us"], 123)
            automatic = next(analyze(report, sender, 100))
            self.assertEqual(automatic["sender_round"], result["sender_round"])
            report.write_text(report.read_text().replace(
                "network_probe_trace_v2", "2\treliable_stream\t1\t4\t1\t488\t100\t1\t100\t100\n"
                "network_probe_trace_v2").replace("app_diagnostics_v1",
                "1800000000\t1500000000\napp_diagnostics_v1"), encoding="utf-8")
            with sender.open("a", encoding="utf-8") as output:
                for i in range(100, 200):
                    output.write(json.dumps({"type": "packet", "sequence": i,
                        "captured_at_ns": i * 10_000_000, "send_at_ns": i * 10_000_000,
                        "send_accepted": True, "send_state": "unknown"}) + "\n")
            empty_round = list(analyze(report, sender, 100))[1]
            self.assertEqual(empty_round["received_unique"], 0)
            self.assertEqual(empty_round["receiver_heartbeat_scope"], "planned_round")
            self.assertEqual(empty_round["receiver_heartbeat_lateness_ms"]["max"], 300)


if __name__ == "__main__":
    unittest.main()
