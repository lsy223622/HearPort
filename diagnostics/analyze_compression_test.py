"""Analyze real compression summaries and synthetic network probe reports.

`missing_frames` is the receiver's playout-time missing audio, including frames
that arrived too late. Packet delivery remains a separate transport metric.
Synthetic network probes carry timed wire records rather than encoded music.
Repeat and PCM-baseline differences are descriptive, not causal or significance
claims.
"""

import argparse
import json
import re
import shlex
from collections import defaultdict
from pathlib import Path


_ROUND_FIELDS = (
    "source", "side", "stream_id", "session_id", "test_id", "round",
    "profile", "repeat", "transport",
)
_SYNTHETIC_PROFILES = (
    (992, 400, "float_pcm32", None),
    (512, 400, "pcm_s16le", None),
    (112, 400, "opus_256_equivalent", 256_000),
    (192, 200, "opus_256_equivalent", 256_000),
    (352, 100, "opus_256_equivalent", 256_000),
    (92, 400, "opus_192_equivalent", 192_000),
    (152, 200, "opus_192_equivalent", 192_000),
    (272, 100, "opus_192_equivalent", 192_000),
    (112, 200, "frequency_control", None),
    (112, 100, "frequency_control", None),
)
_PAIR_CONFIG_FIELDS = (
    "codec", "bitrate", "frame_count", "duration_seconds", "sample_rate",
    "target_ms", "maximum_ms", "output_reserve_ms", "profile_label", "payload_bytes",
    "packets_per_second", "burst_packets", "wire_bytes_scope",
)
_EVENT_NAMES = (
    "compression_summary", "compression_round", "compression_packet",
    "network_probe_round_start", "network_probe_round_end",
)


def _value(value):
    if isinstance(value, str):
        lower = value.lower()
        if lower in ("true", "false"):
            return lower == "true"
        try:
            return int(value, 10)
        except ValueError:
            try:
                return float(value)
            except ValueError:
                return value
    return value


def _key_value_message(message):
    try:
        tokens = shlex.split(message)
    except ValueError:
        return None, {}
    if not tokens:
        return None, {}
    event_name = tokens[0]
    fields = {}
    for token in tokens[1:]:
        key, separator, value = token.partition("=")
        if separator:
            fields[key] = _value(value)
    return event_name, fields


def _event(raw):
    if not isinstance(raw, dict):
        return None, {}
    record = dict(raw)
    nested = record.get("fields")
    if isinstance(nested, dict):
        record = {**record, **nested}
    message = record.get("message")
    if isinstance(message, str):
        message_name, message_fields = _key_value_message(message)
        if message_name in ("compression_round", "compression_summary",
                            "compression_packet", "network_probe_round_start",
                            "network_probe_round_end"):
            return message_name, {**record, **message_fields}
    name = (record.get("kind") or record.get("event") or record.get("name") or
            record.get("type"))
    if name not in ("compression_round", "compression_summary", "compression_packet",
                    "network_probe_round_start", "network_probe_round_end"):
        return None, record
    return name, record


def _plain_event(line):
    """Parse a timestamped HearPort key/value diagnostic line, if present."""
    for event_name in _EVENT_NAMES:
        match = re.search(rf"(?<![A-Za-z0-9_]){event_name}(?![A-Za-z0-9_])", line)
        if match:
            tail = line[match.end():].strip()
            if "|" in tail:
                tail = tail.split("|", 1)[1].strip()
            try:
                fields = {}
                for token in shlex.split(tail):
                    key, separator, value = token.partition("=")
                    if separator:
                        fields[key] = _value(value)
            except ValueError:
                return event_name, None
            return event_name, fields
    return None, None


def _normalize_fields(fields):
    result = {key: _value(value) for key, value in fields.items()}
    if result.get("bitrate") is None and result.get("bitrate_kbps") is not None:
        result["bitrate"] = float(result["bitrate_kbps"]) * 1000
    if result.get("path_id") is None:
        result["path_id"] = result.get("physical_path", result.get("path"))
    codec = result.get("codec")
    if isinstance(codec, str):
        result["codec"] = {
            "pcm_float32": "float_pcm",
            "float_pcm32": "float_pcm",
            "pcm_s16le": "pcm16",
        }.get(codec.lower(), codec)
    return result


def _parse_network_report(lines):
    """Read synthetic round, trace, and playback tables from an iPad export."""
    context = {}
    rounds = {}
    playback = defaultdict(list)
    trace = defaultdict(list)
    compression_summaries = []
    section = None
    header = None
    report_headers = {
        "network_probe_rounds_v3": "rounds",
        "network_probe_rounds_v4": "rounds",
        "network_probe_trace_v3": "trace",
        "network_probe_playback_v1": "playback",
    }
    for line in lines:
        value = line.strip()
        if not value:
            continue
        if value == "compression_summary_json_v1":
            section = "compression_summaries"
            header = None
            continue
        if value in report_headers:
            section = report_headers[value]
            header = None
            continue
        if value.startswith("network_probe_") or value == "app_diagnostics_v1":
            section = None
            header = None
            continue
        if section == "compression_summaries" and re.fullmatch(r"[a-z][a-z0-9_]*_v[0-9]+", value):
            section = None
            header = None
            continue
        if section:
            if section == "compression_summaries":
                try:
                    raw = json.loads(value)
                except json.JSONDecodeError as error:
                    raise ValueError("malformed compression_summary JSON in iPad report") from error
                event_name, fields = _event(raw)
                if event_name is None and isinstance(raw, dict) and any(
                        name in raw for name in ("side", "round", "profile", "repeat")):
                    event_name, fields = "compression_summary", raw
                if event_name != "compression_summary":
                    raise ValueError("malformed compression_summary JSON in iPad report")
                compression_summaries.append(fields)
                continue
            if header is None:
                header = value.split("\t")
                continue
            columns = value.split("\t")
            if len(columns) != len(header):
                continue
            row = {key: _value(item) for key, item in zip(header, columns)}
            if section == "rounds":
                try:
                    round_number = int(row["round"])
                except (KeyError, TypeError, ValueError):
                    continue
                rounds[round_number] = row
            elif section == "playback":
                try:
                    round_number = int(row["round"])
                except (KeyError, TypeError, ValueError):
                    continue
                playback[round_number].append(row)
            else:
                try:
                    stream_id = int(row.get("stream_id", context.get("stream_id", 0)))
                    sequence = int(row["sequence"])
                except (TypeError, ValueError, KeyError):
                    continue
                trace[stream_id].append({**row, "sequence": sequence})
            continue
        if "=" in value and "\t" not in value:
            key, _, item = value.partition("=")
            if key in ("session_id", "stream_id", "physical_path", "connection_id",
                       "target_ms", "maximum_ms", "output_reserve_ms", "end_reason"):
                context[key] = _value(item)

    context["path_id"] = context.get("physical_path")
    if not rounds:
        return [], context, compression_summaries

    context["source"] = "synthetic"
    context["sample_rate"] = 48_000
    context["evidence_kind"] = "network_probe_wire_only"
    trace_rows = trace.get(int(context.get("stream_id", 0)), [])
    summaries = []
    for number, row in rounds.items():
        try:
            profile = int(row["variant"])
            payload_bytes = int(row["payload_bytes"])
            packets_per_second = int(row["packets_per_second"])
            repeat = int(row["repeat"])
            duration_seconds = float(row["seconds"])
            expected_packets = packets_per_second * int(duration_seconds)
            if (not 0 <= profile < len(_SYNTHETIC_PROFILES) or
                    (payload_bytes, packets_per_second) != _SYNTHETIC_PROFILES[profile][:2] or
                    repeat not in (1, 2) or duration_seconds != 30 or
                    int(row.get("planned", expected_packets)) != expected_packets):
                continue
        except (KeyError, TypeError, ValueError):
            continue

        _, _, profile_label, bitrate = _SYNTHETIC_PROFILES[profile]
        first_sequence = int(row.get("first_sequence", 0))
        received_packets = [packet for packet in trace_rows
                            if first_sequence <= packet["sequence"] < first_sequence + expected_packets and
                            int(packet.get("kind", 4)) != 1]
        playback_rows = playback.get(number, [])
        missing_frames = None
        complete = 0
        if playback_rows:
            concealed = sum(int(item.get("concealed_frames", 0)) for item in playback_rows)
            skipped = sum(int(item.get("skipped_frames", 0)) for item in playback_rows)
            played = sum(int(item.get("played_frames", 0)) for item in playback_rows)
            missing_frames = concealed + skipped
            complete = int(played + missing_frames == int(duration_seconds * 48_000))

        late_sequences = set()
        classified_sequences = set()
        maximum_ms = context.get("maximum_ms")
        output_reserve_ms = context.get("output_reserve_ms")
        if maximum_ms is not None and output_reserve_ms is not None:
            allowance_ns = max(0.0, float(maximum_ms) - float(output_reserve_ms)) * 1_000_000
            for packet in received_packets:
                mapped = int(packet.get("mapped_captured_at_ns", 0) or 0)
                received_at = int(packet.get("received_at_ns", 0) or 0)
                uncertainty = int(packet.get("uncertainty_ns", 0) or 0)
                if mapped and received_at:
                    classified_sequences.add(packet["sequence"])
                    if received_at + uncertainty >= mapped + allowance_ns:
                        late_sequences.add(packet["sequence"])

        receiver = {
            **context,
            "side": "receiver",
            "round": number,
            "profile": profile,
            "repeat": repeat,
            "transport": row["transport"],
            "codec": profile_label,
            "profile_label": profile_label,
            "bitrate": bitrate,
            "frame_count": 48_000 // packets_per_second,
            "duration_seconds": duration_seconds,
            "payload_bytes": payload_bytes,
            "packets_per_second": packets_per_second,
            "burst_packets": int(row.get("burst_packets", 1)),
            "packets": expected_packets,
            "planned_packets": expected_packets,
            "received": int(row.get("unique", row.get("received", 0))),
            "missing_frames": missing_frames,
            "complete": complete,
            "late_packets": len(late_sequences) if classified_sequences else None,
            "wire_bytes": (sum(int(packet.get("payload_bytes", 0) or 0)
                               for packet in received_packets) if received_packets else None),
            "wire_bytes_scope": "receiver_observed_timed_records",
            "target_ms": context.get("target_ms"),
            "maximum_ms": maximum_ms,
            "output_reserve_ms": output_reserve_ms,
            "evidence_kind": "network_probe_wire_only",
        }
        summaries.append(receiver)
    return summaries, context, compression_summaries


def _round_key(fields):
    return (
        str(fields.get("source", "unspecified")),
        str(fields.get("session_id", fields.get("test_id", ""))),
        str(fields.get("stream_id", "")),
        _value(fields.get("round")),
        _value(fields.get("profile")),
        _value(fields.get("repeat")),
        str(fields.get("transport", "")),
    )


def _summary_stats(fields):
    excluded = set(_ROUND_FIELDS) | {"kind", "event", "name", "message", "fields"}
    return {key: _value(value) for key, value in fields.items() if key not in excluded}


def _packet_stats(rows):
    sequences = [row.get("sequence") for row in rows if row.get("sequence") is not None]
    result = {"packet_count": len(set(sequences)) if sequences else len(rows)}
    for key in ("wire_bytes", "encode_ns", "decode_ns"):
        values = [float(row[key]) for row in rows if row.get(key) is not None]
        if values:
            result[f"packet_{key}"] = sum(values)
    late = [row.get("late") for row in rows if "late" in row]
    if late:
        result["packet_late_count"] = sum(bool(value) for value in late)
    return result


def _merge_side(summary, packets, side_name):
    if summary is None and not packets:
        return None
    result = {} if summary is None else dict(summary)
    result["side"] = side_name
    result["summary_available"] = summary is not None
    packet_values = _packet_stats(packets)
    result.update(packet_values)
    if "packets" not in result and "packet_count" in result:
        result["packets"] = result["packet_count"]
    if "received" not in result and result.get("side") == "receiver":
        result["received"] = result.get("packet_count")
    if "wire_bytes" not in result and "packet_wire_bytes" in result:
        result["wire_bytes"] = result["packet_wire_bytes"]
    for key in ("encode_ns", "decode_ns"):
        if key not in result and f"packet_{key}" in result:
            result[key] = result[f"packet_{key}"]
    if "late_packets" not in result and "packet_late_count" in result:
        result["late_packets"] = result["packet_late_count"]
    return result


def _round_result(key, fields, summaries, packets):
    source, session_id, stream_id, round_number, profile, repeat, transport = key
    sender_key = (key, "sender")
    receiver_key = (key, "receiver")
    sender = _merge_side(summaries.get(sender_key), packets.get(sender_key, []), "sender")
    receiver = _merge_side(summaries.get(receiver_key), packets.get(receiver_key, []), "receiver")

    metadata = {}
    for name in ("codec", "bitrate", "frame_count", "duration_seconds", "sample_rate",
                 "target_ms", "maximum_ms", "output_reserve_ms", "profile_label", "evidence_kind", "payload_bytes",
                 "packets_per_second", "burst_packets", "wire_bytes_scope"):
        for side in (sender, receiver):
            if side is not None and side.get(name) is not None:
                metadata[name] = side[name]
                break
    metadata.setdefault("sample_rate", 48_000)
    path_identity = {}
    for side_name, side in (("sender", sender), ("receiver", receiver)):
        if side is not None:
            identity = {name: side[name] for name in ("path_id", "connection_id")
                        if side.get(name) is not None}
            if identity:
                path_identity[side_name] = identity

    round_flags = []
    synthetic_receiver_only = (source == "synthetic" and
                               fields.get("evidence_kind") == "network_probe_wire_only")
    required_sides = (("receiver", receiver),) if synthetic_receiver_only else (
        ("sender", sender), ("receiver", receiver))
    for side_name, side in required_sides:
        if side is None or not side.get("summary_available"):
            round_flags.append(f"{side_name}_missing")
        elif side.get("complete") is not None and not bool(side["complete"]):
            round_flags.append(f"{side_name}_incomplete")
    if sender is not None and receiver is not None:
        for name in ("codec", "bitrate", "frame_count", "duration_seconds", "sample_rate",
                     "target_ms", "maximum_ms", "output_reserve_ms"):
            sender_value, receiver_value = sender.get(name), receiver.get(name)
            if (sender_value is not None and receiver_value is not None and
                    sender_value != receiver_value):
                round_flags.append(f"sender_receiver_{name}_mismatch")

    duration = metadata.get("duration_seconds")
    missing_frames = receiver.get("missing_frames") if receiver else None
    missing_source = "receiver_missing_frames" if missing_frames is not None else None
    if missing_frames is None and receiver is not None:
        if receiver.get("missing_before_jitter") is not None and receiver.get("frame_count") is not None:
            missing_frames = float(receiver["missing_before_jitter"]) * float(receiver["frame_count"])
            missing_source = "missing_before_jitter_packets_times_frame_count"
        elif receiver.get("decoded_admitted_frames") is not None and duration is not None:
            missing_frames = max(
                0.0,
                float(duration) * float(metadata["sample_rate"]) -
                float(receiver["decoded_admitted_frames"]),
            )
            missing_source = "round_frames_minus_decoded_admitted_frames"
    denominator = (float(duration) * float(metadata["sample_rate"])
                   if duration is not None and metadata.get("sample_rate") else None)
    missing_fraction = (float(missing_frames) / denominator
                        if missing_frames is not None and denominator else None)

    accepted = sender.get("accepted") if sender else None
    received = receiver.get("received") if receiver else None
    packet_loss = (max(0.0, float(accepted) - float(received)) / float(accepted)
                   if accepted is not None and received is not None and float(accepted) > 0
                   else None)
    if (packet_loss is None and synthetic_receiver_only and receiver is not None and
            receiver.get("planned_packets") is not None and receiver.get("received") is not None and
            float(receiver["planned_packets"]) > 0):
        packet_loss = max(0.0, float(receiver["planned_packets"]) - float(receiver["received"])) / float(receiver["planned_packets"])
    late_packets = receiver.get("late_packets") if receiver else None
    late_fraction = (float(late_packets) / float(received)
                     if late_packets is not None and received is not None and float(received) > 0
                     else None)

    encode_ns_per_frame = None
    if sender is not None and sender.get("encode_ns") is not None:
        sent_count = sender.get("packets")
        frames_per_packet = sender.get("frame_count", metadata.get("frame_count"))
        if sent_count is not None and frames_per_packet is not None and float(sent_count) > 0:
            encode_ns_per_frame = (float(sender["encode_ns"]) /
                                   (float(sent_count) * float(frames_per_packet)))
    decode_ns_per_frame = None
    if receiver is not None and receiver.get("decode_ns") is not None:
        received_count = receiver.get("received")
        frames_per_packet = receiver.get("frame_count", metadata.get("frame_count"))
        if received_count is not None and frames_per_packet is not None and float(received_count) > 0:
            decode_ns_per_frame = (float(receiver["decode_ns"]) /
                                   (float(received_count) * float(frames_per_packet)))

    return {
        "source": source,
        "session_id": session_id or None,
        "stream_id": stream_id or None,
        "round": round_number,
        "profile": profile,
        "repeat": repeat,
        "transport": transport,
        **metadata,
        "sender": sender,
        "receiver": receiver,
        "path_identity": path_identity,
        "round_complete": not round_flags,
        "round_flags": round_flags,
        "missing_measurement_source": missing_source,
        "time_weighted_missing_fraction": missing_fraction,
        "packet_loss_fraction": packet_loss,
        "late_packet_fraction": late_fraction,
        "encode_ns_per_frame": encode_ns_per_frame,
        "decode_ns_per_frame": decode_ns_per_frame,
    }


def _paired_differences(rounds):
    groups = defaultdict(dict)
    for row in rounds:
        group_key = (row["source"], row["session_id"], row["stream_id"],
                     row["profile"], row["transport"])
        repeat = row["repeat"]
        if repeat in groups[group_key]:
            groups[group_key][repeat] = None
        else:
            groups[group_key][repeat] = row

    metric_names = (
        "time_weighted_missing_fraction", "packet_loss_fraction", "late_packet_fraction",
        "encode_ns_per_frame", "decode_ns_per_frame",
    )
    results = []
    for (source, session_id, stream_id, profile, transport), repeats in sorted(
            groups.items(), key=lambda item: tuple(str(part) for part in item[0])):
        first, second = repeats.get(1), repeats.get(2)
        flags = []
        if first is None:
            flags.append("missing_or_duplicate_repeat_1")
        if second is None:
            flags.append("missing_or_duplicate_repeat_2")
        identity_mismatch = False
        identity_incomplete = False
        configuration_mismatch = False
        configuration_incomplete = False
        if first is not None and second is not None:
            if not first["round_complete"]:
                flags.extend(f"repeat_1_{flag}" for flag in first["round_flags"])
            if not second["round_complete"]:
                flags.extend(f"repeat_2_{flag}" for flag in second["round_flags"])
            for name in _PAIR_CONFIG_FIELDS:
                first_value, second_value = first.get(name), second.get(name)
                if first_value is not None and second_value is not None and first_value != second_value:
                    configuration_mismatch = True
                    flags.append(f"repeat_{name}_changed")
                elif (first_value is None) != (second_value is None):
                    configuration_incomplete = True
                    flags.append(f"repeat_{name}_unavailable")
            for side in ("sender", "receiver"):
                first_identity = first["path_identity"].get(side, {})
                second_identity = second["path_identity"].get(side, {})
                for name in ("path_id", "connection_id"):
                    if (first_identity.get(name) is not None and
                            second_identity.get(name) is not None and
                            first_identity[name] != second_identity[name]):
                        identity_mismatch = True
                        flags.append(f"{side}_{name}_changed")
                    elif (first_identity.get(name) is None) != (second_identity.get(name) is None):
                        identity_incomplete = True
                        flags.append(f"{side}_{name}_unavailable_for_one_repeat")
        if first is None or second is None:
            status = "incomplete_repeat_pair"
            differences = None
        elif not first["round_complete"] or not second["round_complete"]:
            if not first["round_complete"]:
                flags.append("repeat_1_incomplete")
            if not second["round_complete"]:
                flags.append("repeat_2_incomplete")
            status = "incomplete_round"
            differences = None
        elif identity_mismatch:
            status = "identity_mismatch"
            differences = None
        elif identity_incomplete:
            status = "identity_incomplete"
            differences = None
        elif configuration_mismatch:
            status = "configuration_mismatch"
            differences = None
        elif configuration_incomplete:
            status = "configuration_incomplete"
            differences = None
        else:
            differences = {
                name: (second[name] - first[name]
                       if first[name] is not None and second[name] is not None else None)
                for name in metric_names
            }
            first_wire = (first["sender"].get("wire_bytes") if first["sender"] else None)
            second_wire = (second["sender"].get("wire_bytes") if second["sender"] else None)
            if first_wire is None and first["receiver"] is not None:
                first_wire = first["receiver"].get("wire_bytes")
            if second_wire is None and second["receiver"] is not None:
                second_wire = second["receiver"].get("wire_bytes")
            differences["wire_bytes"] = (second_wire - first_wire
                                          if first_wire is not None and second_wire is not None
                                          else None)
            if all(value is None for value in differences.values()):
                status = "incomplete_evidence"
            else:
                status = "compared"
        results.append({
            "source": source,
            "session_id": session_id or None,
            "stream_id": stream_id or None,
            "profile": profile,
            "transport": transport,
            "status": status,
            "flags": flags,
            "repeat_1_round": first["round"] if first else None,
            "repeat_2_round": second["round"] if second else None,
            "path_identity": {
                "repeat_1": first["path_identity"] if first else None,
                "repeat_2": second["path_identity"] if second else None,
            },
            "differences": differences,
        })
    return results


def _row_identity(row):
    values = {}
    for side in ("receiver", "sender"):
        identity = row["path_identity"].get(side, {})
        if identity:
            values[side] = identity
    return values


def _bytes_per_frame(row):
    sender = row.get("sender")
    receiver = row.get("receiver")
    side = sender if sender and sender.get("wire_bytes") is not None else receiver
    if not side or side.get("wire_bytes") is None:
        return None
    packets_sent = side.get("accepted", side.get("packets"))
    frames_per_packet = side.get("frame_count", row.get("frame_count"))
    if packets_sent is None or frames_per_packet is None or float(packets_sent) <= 0:
        return None
    return float(side["wire_bytes"]) / (float(packets_sent) * float(frames_per_packet))


def _direction_consistent(values):
    if len(values) != 2 or any(value is None for value in values):
        return None
    signs = [0 if value == 0 else (1 if value > 0 else -1) for value in values]
    return signs[0] == signs[1]


def _pcm_baseline_comparisons(rounds):
    """Compare each real music profile with profile 0 within each matched repeat."""
    if not rounds:
        return []
    matrix = defaultdict(lambda: defaultdict(list))
    for row in rounds:
        if row["source"] != "real" or row.get("evidence_kind") == "network_probe_wire_only":
            continue
        try:
            profile = int(row["profile"])
            repeat = int(row["repeat"])
        except (TypeError, ValueError):
            continue
        group = (row["source"], row["session_id"], row["stream_id"], row["transport"])
        matrix[group][(profile, repeat)].append(row)

    results = []
    profile_pairs = {(group, profile) for group, values in matrix.items()
                     for profile, _ in values if profile != 0}
    for group, profile in sorted(profile_pairs, key=lambda pair: tuple(str(part) for part in pair)):
        source, session_id, stream_id, transport = group
        repeats = []
        flags = []
        for repeat in (1, 2):
            targets = matrix[group].get((profile, repeat), [])
            baselines = matrix[group].get((0, repeat), [])
            if len(targets) != 1:
                flags.append(f"repeat_{repeat}_profile_missing_or_duplicate")
                repeats.append({"repeat": repeat, "status": "incomplete", "flags": [flags[-1]]})
                continue
            if len(baselines) != 1:
                flags.append(f"repeat_{repeat}_pcm_baseline_missing_or_duplicate")
                repeats.append({"repeat": repeat, "status": "incomplete", "flags": [flags[-1]]})
                continue
            target, baseline = targets[0], baselines[0]
            pair_flags = []
            if not target["round_complete"] or not baseline["round_complete"]:
                pair_flags.append("incomplete_round")
            for name in ("target_ms", "maximum_ms", "output_reserve_ms", "duration_seconds",
                         "sample_rate"):
                if target.get(name) != baseline.get(name):
                    pair_flags.append(f"{name}_mismatch")
            target_identity, baseline_identity = _row_identity(target), _row_identity(baseline)
            if not target_identity or not baseline_identity:
                pair_flags.append("path_identity_unavailable")
            elif target_identity != baseline_identity:
                pair_flags.append("path_identity_mismatch")
            if (target.get("missing_measurement_source") is not None and
                    baseline.get("missing_measurement_source") is not None and
                    target["missing_measurement_source"] != baseline["missing_measurement_source"]):
                pair_flags.append("missing_measurement_source_mismatch")
            if pair_flags:
                flags.extend(f"repeat_{repeat}_{item}" for item in pair_flags)
                repeats.append({"repeat": repeat, "status": "incomparable", "flags": pair_flags})
                continue

            missing_delta = None
            if (target["time_weighted_missing_fraction"] is not None and
                    baseline["time_weighted_missing_fraction"] is not None):
                missing_delta = (target["time_weighted_missing_fraction"] -
                                 baseline["time_weighted_missing_fraction"])
            baseline_bytes = _bytes_per_frame(baseline)
            target_bytes = _bytes_per_frame(target)
            bytes_reduction = (baseline_bytes - target_bytes
                               if baseline_bytes is not None and target_bytes is not None else None)
            repeats.append({
                "repeat": repeat,
                "status": "compared" if missing_delta is not None or bytes_reduction is not None
                else "incomplete_evidence",
                "missing_fraction_delta": missing_delta,
                "baseline_bytes_per_frame": baseline_bytes,
                "profile_bytes_per_frame": target_bytes,
                "bytes_per_frame_reduction": bytes_reduction,
                "baseline_round": baseline["round"],
                "profile_round": target["round"],
                "path_identity": target_identity,
            })

        paired = [item for item in repeats if item.get("status") == "compared"]
        missing_values = [item.get("missing_fraction_delta") for item in paired]
        bytes_values = [item.get("bytes_per_frame_reduction") for item in paired]
        missing_consistency = _direction_consistent(missing_values)
        bytes_consistency = _direction_consistent(bytes_values)
        status = "compared" if len(paired) == 2 and not flags else "incomplete_comparison"
        results.append({
            "source": source,
            "session_id": session_id,
            "stream_id": stream_id,
            "profile": profile,
            "transport": transport,
            "baseline_profile": 0,
            "status": status,
            "flags": flags,
            "repeats": repeats,
            "mean_missing_fraction_delta": (
                sum(missing_values) / len(missing_values)
                if len(missing_values) == 2 and all(value is not None for value in missing_values)
                else None
            ),
            "mean_bytes_per_frame_reduction": (
                sum(bytes_values) / len(bytes_values)
                if len(bytes_values) == 2 and all(value is not None for value in bytes_values)
                else None
            ),
            "missing_fraction_direction_consistent": missing_consistency,
            "bytes_per_frame_direction_consistent": bytes_consistency,
            "both_metrics_direction_consistent": (
                missing_consistency and bytes_consistency
                if missing_consistency is not None and bytes_consistency is not None else None
            ),
            "interpretation": "descriptive repeat comparisons; not a causal or significance claim",
        })
    return results


def analyze(paths):
    """Return round summaries and descriptive repeat and PCM-baseline deltas."""
    if isinstance(paths, (str, Path)):
        paths = [Path(paths)]
    else:
        paths = [Path(path) for path in paths]
    summaries = {}
    packets = defaultdict(list)
    metadata = {}
    input_rows = []
    global_stream_contexts = {}
    for path in paths:
        with path.open(encoding="utf-8", errors="replace") as source:
            lines = source.readlines()
        synthetic_rows, report_context, dedicated_summaries = _parse_network_report(lines)
        input_rows.append((path, lines, synthetic_rows, report_context,
                           dedicated_summaries))
        stream_id = report_context.get("stream_id")
        if stream_id is not None:
            stream_key = str(stream_id)
            prior = global_stream_contexts.get(stream_key, report_context)
            if prior is None or (prior.get("session_id") != report_context.get("session_id") or
                                 prior.get("connection_id") != report_context.get("connection_id")):
                global_stream_contexts[stream_key] = None
            else:
                global_stream_contexts[stream_key] = report_context

    for path, lines, synthetic_rows, report_context, dedicated_summaries in input_rows:
        pending_network_rounds = {}
        for fields in synthetic_rows:
            key = _round_key(fields)
            metadata[key] = fields
            summaries[(key, "receiver")] = _summary_stats(fields)

        for line_number, dedicated in enumerate(dedicated_summaries, 1):
            fields = _normalize_fields(dedicated)
            for name in ("session_id", "stream_id", "path_id", "connection_id",
                         "target_ms", "maximum_ms", "output_reserve_ms"):
                if fields.get(name) is None and report_context.get(name) is not None:
                    fields[name] = report_context[name]
            if fields.get("source") is None:
                fields["source"] = "real"
            if fields.get("side") not in ("sender", "receiver") or any(
                    fields.get(name) is None for name in ("round", "profile", "repeat", "transport")):
                raise ValueError(f"malformed compression_summary JSON on {path} dedicated row {line_number}")
            key = _round_key(fields)
            metadata[key] = fields
            summaries[(key, fields["side"])] = _summary_stats(fields)

        in_app_diagnostics = False
        in_dedicated_summaries = False
        for line_number, line in enumerate(lines, 1):
            if not line.strip():
                continue
            stripped = line.lstrip()
            if stripped.strip() == "app_diagnostics_v1":
                in_app_diagnostics = True
                in_dedicated_summaries = False
                continue
            if stripped.strip() == "compression_summary_json_v1":
                in_dedicated_summaries = True
                in_app_diagnostics = False
                continue
            if in_dedicated_summaries:
                continue
            if stripped.startswith("{"):
                try:
                    raw = json.loads(line)
                except json.JSONDecodeError as error:
                    if "compression_summary" in line:
                        raise ValueError(
                            f"malformed compression_summary JSON on {path} line {line_number}"
                        ) from error
                    continue
                event_name, fields = _event(raw)
            else:
                event_name, fields = _plain_event(line)
            if event_name is None:
                continue
            if fields is None:
                raise ValueError(f"malformed {event_name} diagnostic on {path} line {line_number}")
            if dedicated_summaries and in_app_diagnostics and event_name == "compression_summary":
                continue
            fields = _normalize_fields(fields)
            if fields.get("stream_id") is not None:
                context = global_stream_contexts.get(str(fields["stream_id"]), report_context)
                if context is None:
                    context = report_context if report_context.get("stream_id") is not None else {}
                if context:
                    for key in ("path_id", "connection_id", "target_ms", "maximum_ms",
                                "output_reserve_ms"):
                        if fields.get(key) is None and context.get(key) is not None:
                            fields[key] = context[key]
                    if fields.get("session_id") is None and context.get("session_id") is not None:
                        fields["session_id"] = context["session_id"]
            if event_name == "network_probe_round_start":
                if fields.get("round") is None:
                    continue
                pending_network_rounds[fields.get("round")] = fields
                continue
            if event_name == "network_probe_round_end":
                start = pending_network_rounds.pop(fields.get("round"), None)
                if start is None:
                    continue
                profile = start.get("variant")
                payload_bytes = start.get("payload_bytes")
                rate = start.get("packets_per_second")
                if (not isinstance(profile, int) or not 0 <= profile < len(_SYNTHETIC_PROFILES) or
                        (payload_bytes, rate) != _SYNTHETIC_PROFILES[profile][:2] or
                        start.get("repeat") not in (1, 2)):
                    continue
                _, _, profile_label, bitrate = _SYNTHETIC_PROFILES[profile]
                accepted = fields.get("send_accepted")
                context = global_stream_contexts.get(str(fields.get("stream_id")), report_context)
                if context is None:
                    context = {}
                fields = {
                    "source": "synthetic", "side": "sender",
                    "session_id": start.get("session_id", fields.get("session_id", context.get("session_id"))),
                    "stream_id": fields.get("stream_id"), "round": start.get("round"),
                    "profile": profile, "repeat": start["repeat"],
                    "transport": start.get("transport"),
                    "codec": profile_label, "profile_label": profile_label,
                    "bitrate": bitrate, "frame_count": 48_000 // rate,
                    "duration_seconds": 30, "sample_rate": 48_000,
                    "payload_bytes": payload_bytes, "packets_per_second": rate,
                    "burst_packets": start.get("burst_packets"),
                    "evidence_kind": "network_probe_wire_only",
                    "packets": rate * 30, "accepted": accepted,
                    "rejected": fields.get("send_rejected"),
                    "wire_bytes": (accepted * payload_bytes +
                                   fields.get("repair_sent_bytes", 0)
                                   if accepted is not None else None),
                    "wire_bytes_scope": "timed_audio_record_payload",
                    "path_id": start.get("path_id", fields.get("path_id", context.get("path_id"))),
                    "connection_id": start.get("connection_id", fields.get("connection_id", context.get("connection_id"))),
                }
                key = _round_key(fields)
                metadata[key] = fields
                summaries[(key, "sender")] = _summary_stats(fields)
                continue
            if event_name == "compression_round" and "packets" not in fields:
                continue
            if event_name == "compression_summary":
                required = ("round", "profile", "repeat", "transport")
                if (fields.get("side") not in ("sender", "receiver") or
                        any(fields.get(name) is None for name in required)):
                    raise ValueError(
                        f"malformed compression_summary diagnostic on {path} line {line_number}"
                    )
            if fields.get("side") not in ("sender", "receiver"):
                continue
            key = _round_key(fields)
            metadata[key] = fields
            side_key = (key, fields["side"])
            if event_name == "compression_packet":
                packets[side_key].append(fields)
            else:
                summaries[side_key] = _summary_stats(fields)
    if not summaries and not packets:
        raise ValueError("inputs contain no compression summaries or supported synthetic round data")

    keys = sorted(set(key for key, _ in summaries) | set(key for key, _ in packets),
                  key=lambda key: tuple(str(part) for part in key))
    rounds = [_round_result(key, metadata[key], summaries, packets) for key in keys]
    return {
        "schema": "hearport-compression-analysis-v1",
        "pairing": "descriptive repeat 2 minus repeat 1 within source, session, stream, profile, and transport",
        "rounds": rounds,
        "paired_differences": _paired_differences(rounds),
        "pcm_baseline_comparisons": _pcm_baseline_comparisons(rounds),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, nargs="+",
                        help="JSONL/plain diagnostics or iPad network report")
    args = parser.parse_args()
    try:
        print(json.dumps(analyze(args.input), ensure_ascii=False, sort_keys=True))
    except ValueError as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
