import json
import tempfile
import unittest
from pathlib import Path

from diagnostics.analyze_compression_test import analyze


def summary(source, side, round_number, repeat, *, stream_id="7", profile="2",
            transport="datagram", path_id="wifi-1", **fields):
    return {
        "kind": "compression_summary",
        "source": source,
        "side": side,
        "stream_id": stream_id,
        "round": round_number,
        "profile": profile,
        "repeat": repeat,
        "transport": transport,
        "codec": "opus",
        "bitrate": 256000,
        "frame_count": 120,
        "duration_seconds": 30,
        "target_ms": 100,
        "maximum_ms": 200,
        "path_id": path_id,
        "connection_id": "connection-1",
        "complete": 1,
        **fields,
    }


class CompressionAnalysisTests(unittest.TestCase):
    def analyze_rows(self, rows):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "compression.jsonl"
            path.write_text("".join(json.dumps(row) + "\n" for row in rows),
                            encoding="utf-8")
            return analyze(path)

    def test_missing_fraction_is_time_weighted_and_distinct_from_packet_loss(self):
        rows = [
            summary("synthetic", "sender", 1, 1,
                    packets=12000, accepted=11900, wire_bytes=990000,
                    encode_ns=12000000),
            summary("synthetic", "receiver", 1, 1,
                    received=11800, missing_frames=2880, late_packets=40,
                    wire_bytes=970000, decode_ns=18000000),
        ]
        result = self.analyze_rows(rows)["rounds"][0]
        self.assertAlmostEqual(result["time_weighted_missing_fraction"], 0.002)
        self.assertNotAlmostEqual(result["time_weighted_missing_fraction"],
                                  result["packet_loss_fraction"])
        self.assertEqual(result["packet_loss_fraction"], (11900 - 11800) / 11900)

    def test_only_same_source_profile_transport_and_stream_are_paired(self):
        rows = [
            summary("synthetic", "sender", 1, 1, packets=12000, accepted=12000,
                    wire_bytes=900000, encode_ns=12000000),
            summary("synthetic", "receiver", 1, 1, received=12000,
                    missing_frames=480, late_packets=0, decode_ns=24000000),
            summary("synthetic", "sender", 2, 2, packets=12000, accepted=12000,
                    wire_bytes=880000, encode_ns=10000000),
            summary("synthetic", "receiver", 2, 2, received=12000,
                    missing_frames=960, late_packets=0, decode_ns=22000000),
            summary("real", "receiver", 3, 1, missing_frames=0, received=12000),
            summary("real", "receiver", 4, 2, missing_frames=480, received=12000),
            summary("real", "sender", 3, 1, packets=12000, accepted=12000,
                    wire_bytes=900000),
            summary("real", "sender", 4, 2, packets=12000, accepted=12000,
                    wire_bytes=880000),
        ]
        result = self.analyze_rows(rows)
        synthetic = next(item for item in result["paired_differences"]
                         if item["source"] == "synthetic")
        real = next(item for item in result["paired_differences"]
                    if item["source"] == "real")
        self.assertEqual(synthetic["status"], "compared")
        self.assertAlmostEqual(
            synthetic["differences"]["time_weighted_missing_fraction"], 480 / 1_440_000)
        self.assertEqual(synthetic["differences"]["wire_bytes"], -20000)
        self.assertEqual(real["status"], "compared")
        self.assertEqual(real["differences"]["time_weighted_missing_fraction"],
                         480 / 1_440_000)
        self.assertNotIn("p_value", synthetic)

    def test_incomplete_repeat_and_path_changes_are_flagged_without_comparison(self):
        rows = [
            summary("synthetic", "receiver", 1, 1, profile=5,
                    received=100, missing_frames=10),
            summary("synthetic", "receiver", 2, 2, profile=6,
                    received=100, missing_frames=20, path_id="wifi-2"),
            summary("synthetic", "receiver", 3, 1, profile=7,
                    received=100, missing_frames=10),
            summary("synthetic", "receiver", 4, 2, profile=7,
                    received=100, missing_frames=20, path_id="wifi-2"),
            summary("synthetic", "sender", 3, 1, profile=7, packets=100,
                    accepted=100, wire_bytes=10000),
            summary("synthetic", "sender", 4, 2, profile=7, packets=100,
                    accepted=100, wire_bytes=10000),
        ]
        result = self.analyze_rows(rows)
        by_profile = {item["profile"]: item for item in result["paired_differences"]}
        self.assertEqual(by_profile[5]["status"], "incomplete_repeat_pair")
        self.assertIn("missing_or_duplicate_repeat_2", by_profile[5]["flags"])
        self.assertEqual(by_profile[7]["status"], "identity_mismatch")
        self.assertIsNone(by_profile[7]["differences"])

    def test_aborted_or_sender_receiver_incomplete_rounds_are_not_compared(self):
        rows = [
            summary("synthetic", "sender", 1, 1, packets=100, accepted=100,
                    wire_bytes=10000),
            summary("synthetic", "receiver", 1, 1, received=100, missing_frames=10),
            summary("synthetic", "sender", 2, 2, packets=100, accepted=100,
                    wire_bytes=10000, complete=0),
            summary("synthetic", "receiver", 2, 2, received=100, missing_frames=20),
        ]
        result = self.analyze_rows(rows)["paired_differences"][0]
        self.assertEqual(result["status"], "incomplete_round")
        self.assertIn("repeat_2_incomplete", result["flags"])
        self.assertIsNone(result["differences"])

        incomplete = self.analyze_rows([
            summary("synthetic", "sender", 1, 1, packets=100, accepted=100),
            summary("synthetic", "sender", 2, 2, packets=100, accepted=100),
        ])["paired_differences"][0]
        self.assertEqual(incomplete["status"], "incomplete_round")
        self.assertIn("repeat_1_receiver_missing", incomplete["flags"])

    def test_changed_audio_and_buffer_configuration_suppresses_pairing(self):
        rows = []
        changes = {
            3: {"target_ms": 80},
            4: {"maximum_ms": 250},
            5: {"frame_count": 240},
            6: {"bitrate": 192000},
        }
        for profile, changed in changes.items():
            for repeat in (1, 2):
                round_number = profile * 10 + repeat
                config = changed if repeat == 2 else {}
                rows.extend([
                    summary("synthetic", "sender", round_number, repeat,
                            profile=profile, packets=100, accepted=100,
                            wire_bytes=10000, **config),
                    summary("synthetic", "receiver", round_number, repeat,
                            profile=profile, received=100, missing_frames=10,
                            **config),
                ])
        for profile, field, value in ((7, "path_id", "wifi-2"),
                                      (8, "connection_id", "connection-2")):
            for repeat in (1, 2):
                round_number = profile * 10 + repeat
                identity = {field: value} if repeat == 2 else {}
                rows.extend([
                    summary("synthetic", "sender", round_number, repeat,
                            profile=profile, packets=100, accepted=100,
                            wire_bytes=10000, **identity),
                    summary("synthetic", "receiver", round_number, repeat,
                            profile=profile, received=100, missing_frames=10,
                            **identity),
                ])

        pairs = {row["profile"]: row for row in self.analyze_rows(rows)["paired_differences"]}
        for profile, field in ((3, "target_ms"), (4, "maximum_ms"),
                               (5, "frame_count"), (6, "bitrate")):
            self.assertEqual(pairs[profile]["status"], "configuration_mismatch")
            self.assertIn(f"repeat_{field}_changed", pairs[profile]["flags"])
            self.assertIsNone(pairs[profile]["differences"])
        self.assertEqual(pairs[7]["status"], "identity_mismatch")
        self.assertEqual(pairs[8]["status"], "identity_mismatch")

    def test_absent_receiver_missing_measurement_is_not_reported_as_zero(self):
        result = self.analyze_rows([
            summary("synthetic", "receiver", 1, 1, profile=8, received=12000),
        ])
        row = result["rounds"][0]
        self.assertIsNone(row["time_weighted_missing_fraction"])
        self.assertIsNone(row["receiver"].get("missing_frames"))

    def test_missing_before_jitter_can_supply_a_separately_labeled_frame_estimate(self):
        row = self.analyze_rows([
            summary("real", "sender", 1, 1, packets=100, accepted=100, wire_bytes=12000),
            summary("real", "receiver", 1, 1, received=98, missing_before_jitter=2),
        ])["rounds"][0]
        self.assertAlmostEqual(row["time_weighted_missing_fraction"], 240 / 1_440_000)
        self.assertEqual(row["missing_measurement_source"],
                         "missing_before_jitter_packets_times_frame_count")

    def test_key_value_diagnostic_wrappers_and_packet_rows_are_consumed(self):
        rows = [
            {"message": "compression_round source=synthetic side=sender stream_id=8 round=1 profile=9 repeat=1 transport=reliable_stream codec=pcm_s16le bitrate=0 frame_count=480 duration_seconds=30 target_ms=100 maximum_ms=200"},
            {"message": "compression_summary source=synthetic side=sender stream_id=8 round=1 profile=9 repeat=1 transport=reliable_stream codec=pcm_s16le bitrate=0 frame_count=480 duration_seconds=30 target_ms=100 maximum_ms=200 packets=3000 accepted=3000 encode_ns=5000"},
            {"kind": "compression_packet", "source": "synthetic", "side": "sender",
             "stream_id": 8, "round": 1, "profile": 9, "repeat": 1,
             "transport": "reliable_stream", "sequence": 1, "wire_bytes": 96},
        ]
        result = self.analyze_rows(rows)
        self.assertEqual(len(result["rounds"]), 1)
        self.assertEqual(result["rounds"][0]["sender"]["packets"], 3000)
        self.assertEqual(result["rounds"][0]["sender"]["packet_wire_bytes"], 96)
        self.assertIsNone(result["rounds"][0]["time_weighted_missing_fraction"])

    def test_plain_sender_and_ipad_diagnostic_lines_are_consumed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "hearport.log"
            path.write_text(
                "2026-10-19T10:00:00.000Z [info] [audio] compression_round | "
                "source=real side=sender stream_id=77 round=1 profile=2 repeat=1 "
                "transport=datagram codec=opus bitrate=256000 frame_count=120 "
                "duration_seconds=30 target_ms=100.0 maximum_ms=200.0\n"
                "2026-10-19T10:00:01.000Z [info] [audio] compression_summary | "
                "source=real side=sender stream_id=77 round=1 profile=2 repeat=1 "
                "transport=datagram codec=opus bitrate=256000 frame_count=120 "
                "duration_seconds=30 target_ms=100.0 maximum_ms=200.0 complete=1 "
                "packets=12000 accepted=11990 wire_bytes=1200000 encode_ns=12000000\n"
                "2026-10-19T10:00:02.000Z [info] [audio] compression_summary | "
                "event=compression_summary source=real side=receiver stream_id=77 "
                "round=1 profile=2 repeat=1 transport=datagram codec=opus "
                "bitrate_kbps=256 frame_count=120 duration_seconds=30 target_ms=100.0 "
                "maximum_ms=200.0 complete=1 received=11980 missing_frames=480 "
                "late_packets=8 decode_ns=24000000\n"
                "unrelated logger startup message\n",
                encoding="utf-8")
            result = analyze(path)
        self.assertEqual(len(result["rounds"]), 1)
        row = result["rounds"][0]
        self.assertEqual(row["source"], "real")
        self.assertEqual(row["round_complete"], True)
        self.assertEqual(row["receiver"]["bitrate_kbps"], 256)
        self.assertEqual(row["receiver"]["bitrate"], 256000)
        self.assertEqual(row["receiver"]["missing_frames"], 480)
        self.assertEqual(row["receiver"]["late_packets"], 8)

    def test_separate_sender_log_and_receiver_log_join_by_round_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sender = root / "sender.log"
            receiver = root / "receiver.log"
            sender.write_text(
                "compression_summary source=real side=sender stream_id=78 round=3 "
                "profile=4 repeat=1 transport=reliable_stream codec=opus "
                "bitrate=256000 frame_count=240 duration_seconds=30 target_ms=120 "
                "maximum_ms=240 complete=1 packets=6000 accepted=6000 "
                "wire_bytes=780000 encode_ns=12000000\n", encoding="utf-8")
            receiver.write_text(
                "2026-10-19T10:00:02.000Z [info] [audio] compression_summary | "
                "source=real side=receiver stream_id=78 round=3 profile=4 repeat=1 "
                "transport=reliable_stream codec=opus bitrate_kbps=256 "
                "frame_count=240 duration_seconds=30 target_ms=120 maximum_ms=240 "
                "complete=1 received=5999 missing_frames=240 late_packets=1\n",
                encoding="utf-8")
            row = analyze([sender, receiver])["rounds"][0]
        self.assertEqual(row["round_complete"], True)
        self.assertEqual(row["sender"]["accepted"], 6000)
        self.assertEqual(row["receiver"]["received"], 5999)
        self.assertAlmostEqual(row["time_weighted_missing_fraction"], 240 / 1_440_000)

    def test_dedicated_ipad_summary_joins_sender_and_overrides_app_log_duplicate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sender = root / "sender.jsonl"
            receiver = root / "receiver-report.txt"
            sender.write_text(json.dumps({
                "message": "compression_summary source=real side=sender stream_id=7 "
                           "session_id=abcd connection_id=abcd path_id=network round=1 "
                           "profile=0 repeat=1 transport=datagram codec=pcm_float32 "
                           "bitrate=0 frame_count=480 duration_seconds=30 sample_rate=48000 "
                           "target_ms=100 maximum_ms=200 output_reserve_ms=10 complete=1 "
                           "packets=3000 accepted=3000 wire_bytes=138240000 encode_ns=0"
            }) + "\n", encoding="utf-8")
            dedicated = {
                "event": "compression_summary", "source": "real", "side": "receiver",
                "stream_id": "7", "round": "1", "profile": "0", "repeat": "1",
                "transport": "datagram", "codec": "float_pcm", "bitrate": "0",
                "frame_count": "480", "duration_seconds": "30", "target_ms": "100",
                "maximum_ms": "200", "output_reserve_ms": "10", "complete": "1",
                "packets": "3000", "received": "3000", "missing_frames": "480",
                "wire_bytes": "138240000", "decode_ns": "12000000",
            }
            receiver.write_text(
                "HearPort receiver diagnostic report\nformat_version=1\n"
                "physical_path=wifi\nconnection_id=receiver-conn\nsession_id=abcd\n"
                "stream_id=7\ntarget_ms=100\nmaximum_ms=200\noutput_reserve_ms=10\n"
                "compression_summary_json_v1\n"
                + json.dumps(dedicated, sort_keys=True) + "\n"
                + "packet_trace_v1\nreceived_at_ns\\tstream_id\\tsequence\\n"
                + "app_diagnostics_v1\n"
                + "2026-10-19T10:00:02.000Z [info] [audio] compression_summary | "
                  "source=real side=receiver stream_id=7 round=1 profile=0 repeat=1 "
                  "transport=datagram codec=float_pcm bitrate=0 frame_count=480 "
                  "duration_seconds=30 target_ms=100 maximum_ms=200 output_reserve_ms=10 "
                  "complete=1 packets=3000 received=3000 missing_frames=960 "
                  "wire_bytes=138240000 decode_ns=12000000\n",
                encoding="utf-8")

            result = analyze([sender, receiver])

        self.assertEqual(len(result["rounds"]), 1)
        row = result["rounds"][0]
        self.assertEqual(row["source"], "real")
        self.assertEqual(row["round_complete"], True)
        self.assertEqual(row["sender"]["codec"], "float_pcm")
        self.assertEqual(row["receiver"]["missing_frames"], 480)
        self.assertEqual(row["session_id"], "abcd")
        self.assertEqual(row["path_identity"]["receiver"], {
            "path_id": "wifi", "connection_id": "receiver-conn",
        })

    def test_ipad_network_report_builds_synthetic_playout_metrics(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "receiver-report.txt"
            path.write_text(
                "HearPort receiver diagnostic report\n"
                "format_version=1\nphysical_path=wifi\nconnection_id=conn-1\n"
                "session_id=abcd\nstream_id=9\ntarget_ms=100.0\nmaximum_ms=200.0\n"
                "output_reserve_ms=10.0\nprobe_mode=network\n"
                "network_probe_rounds_v4\n"
                "round\ttransport\trepeat\tvariant\tseconds\tpayload_bytes\tpackets_per_second\tburst_packets\tfirst_sequence\tplanned\treceived\tunique\tduplicates\tnot_received\twrong_size\tcontroller\trepair\tcorrection_percent\n"
                "1\tdatagram\t1\t2\t30\t112\t400\t1\t0\t12000\t11998\t11998\t0\t2\t0\t2\t0\t5\n"
                "2\tdatagram\t2\t2\t30\t112\t400\t1\t12000\t12000\t11999\t11999\t1\t1\t0\t2\t0\t5\n"
                "network_probe_trace_v3\n"
                "received_at_ns\tstream_id\tsequence\tpayload_bytes\trecorded_at_ns\tcallback_bytes\tcallback_packets\tcaptured_at_ns\tsource_frame\tgeneration\tkind\tmapped_captured_at_ns\tuncertainty_ns\n"
                "1500000000\t9\t0\t112\t1500000000\t112\t1\t1000000000\t0\t1\t4\t1000000000\t0\n"
                "1500000000\t9\t12000\t112\t1500000000\t112\t1\t1000000000\t1440000\t1\t4\t1000000000\t0\n"
                "network_probe_playback_v1\n"
                "round\tat_ns\tplayed_source_frame\tbuffered_frames\ttarget_ms\tcorrection\tplayed_frames\tconcealed_frames\tskipped_frames\tmaximum_age_ms\trepaired_packets\twaiting_frames\n"
                "1\t30000000000\t0\t0\t100\t0\t1439520\t480\t0\t120\t0\t0\n"
                "2\t60000000000\t0\t0\t100\t0\t1439040\t960\t0\t120\t0\t0\n"
                "network_probe_heartbeat_v1\nat_ns\tscheduled_at_ns\n"
                "app_diagnostics_v1\n",
                encoding="utf-8")
            result = analyze(path)
        self.assertEqual(len(result["rounds"]), 2)
        first, second = sorted(result["rounds"], key=lambda row: row["repeat"])
        self.assertEqual(first["source"], "synthetic")
        self.assertEqual(first["evidence_kind"], "network_probe_wire_only")
        self.assertEqual(first["round_complete"], True)
        self.assertEqual(first["sender"], None)
        self.assertEqual(first["receiver"]["packets"], 12000)
        self.assertEqual(first["receiver"]["late_packets"], 1)
        self.assertAlmostEqual(first["time_weighted_missing_fraction"], 480 / 1_440_000)
        self.assertEqual(second["receiver"]["missing_frames"], 960)
        self.assertEqual(second["receiver"]["late_packets"], 1)
        pair = result["paired_differences"][0]
        self.assertEqual(pair["status"], "compared")
        self.assertAlmostEqual(pair["differences"]["time_weighted_missing_fraction"],
                               480 / 1_440_000)

    def test_real_profiles_are_compared_against_pcm0_within_each_repeat(self):
        rows = []
        values = {
            (0, 1): (480, 120000),
            (2, 1): (960, 60000),
            (0, 2): (960, 120000),
            (2, 2): (480, 60000),
        }
        for (profile, repeat), (missing, wire_bytes) in values.items():
            round_number = profile * 10 + repeat
            codec = "pcm_float32" if profile == 0 else "opus"
            bitrate = 0 if profile == 0 else 256000
            rows.extend([
                summary("real", "sender", round_number, repeat, profile=profile,
                        codec=codec, bitrate=bitrate, frame_count=120,
                        packets=100, accepted=100, wire_bytes=wire_bytes),
                summary("real", "receiver", round_number, repeat, profile=profile,
                        codec=codec, bitrate=bitrate, frame_count=120,
                        received=100, missing_frames=missing),
            ])
        comparison = self.analyze_rows(rows)["pcm_baseline_comparisons"][0]
        self.assertEqual(comparison["profile"], 2)
        self.assertEqual(comparison["status"], "compared")
        self.assertEqual(comparison["mean_missing_fraction_delta"], 0)
        self.assertEqual(comparison["mean_bytes_per_frame_reduction"], 5)
        self.assertEqual(comparison["missing_fraction_direction_consistent"], False)
        self.assertEqual(comparison["bytes_per_frame_direction_consistent"], True)
        self.assertEqual([row["repeat"] for row in comparison["repeats"]], [1, 2])

        changed_path_rows = []
        for (profile, repeat), (missing, wire_bytes) in values.items():
            round_number = profile * 10 + repeat
            codec = "pcm_float32" if profile == 0 else "opus"
            bitrate = 0 if profile == 0 else 256000
            path_id = "wifi-2" if profile == 2 and repeat == 1 else "wifi-1"
            changed_path_rows.extend([
                summary("real", "sender", round_number, repeat, profile=profile,
                        codec=codec, bitrate=bitrate, frame_count=120,
                        packets=100, accepted=100, wire_bytes=wire_bytes,
                        path_id=path_id),
                summary("real", "receiver", round_number, repeat, profile=profile,
                        codec=codec, bitrate=bitrate, frame_count=120,
                        received=100, missing_frames=missing, path_id=path_id),
            ])
        changed = self.analyze_rows(changed_path_rows)["pcm_baseline_comparisons"][0]
        self.assertEqual(changed["status"], "incomplete_comparison")
        self.assertIn("repeat_1_path_identity_mismatch", changed["flags"])

    def test_malformed_plain_compression_summary_is_an_error(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "hearport.log"
            path.write_text("2026-10-19 [info] [audio] compression_summary | broken\n",
                            encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "malformed compression_summary"):
                analyze(path)

    def test_legacy_synthetic_network_probe_logs_keep_wire_only_evidence_separate(self):
        rows = [
            {"message": "network_probe_round_start round=1 variant=2 repeat=1 transport=datagram payload_bytes=112 packets_per_second=400 burst_packets=1 controller=2 repair=0 correction_percent=5 recovery_seconds=0 sequence=0"},
            {"message": "network_probe_round_end round=1 stream_id=9 sequence=12000 send_accepted=11980 send_rejected=20 repair_sent_bytes=0"},
        ]
        result = self.analyze_rows(rows)["rounds"][0]
        self.assertEqual(result["source"], "synthetic")
        self.assertEqual(result["profile"], 2)
        self.assertEqual(result["codec"], "opus_256_equivalent")
        self.assertEqual(result["sender"]["wire_bytes"], 11980 * 112)
        self.assertEqual(result["sender"]["packets"], 12000)
        self.assertEqual(result["sender"]["accepted"], 11980)
        self.assertEqual(result["evidence_kind"], "network_probe_wire_only")
        self.assertEqual(result["wire_bytes_scope"], "timed_audio_record_payload")
        self.assertIsNone(result["time_weighted_missing_fraction"])
        self.assertIsNone(result["encode_ns_per_frame"])

    def test_delivery_loss_is_unknown_without_sender_acceptance_count(self):
        result = self.analyze_rows([
            summary("synthetic", "sender", 1, 1, packets=100, wire_bytes=9000),
            summary("synthetic", "receiver", 1, 1, received=98, missing_frames=240),
        ])["rounds"][0]
        self.assertIsNone(result["packet_loss_fraction"])


if __name__ == "__main__":
    unittest.main()
