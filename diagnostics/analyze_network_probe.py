"""Compare network probe loss stages and virtual receive-buffer behavior."""

import argparse
import json
from collections import Counter
from pathlib import Path


def load_report(path):
    rounds = []
    arrivals = []
    section = None
    stream_id = None
    with path.open(encoding="utf-8") as source:
        for raw in source:
            line = raw.rstrip("\n")
            if line.startswith("stream_id="):
                stream_id = int(line.partition("=")[2])
            elif line in ("network_probe_rounds_v1", "network_probe_rounds_v2",
                          "network_probe_rounds_v3"):
                section = "rounds"
                header = None
            elif line in ("network_probe_trace_v1", "network_probe_trace_v2"):
                section = "trace"
                header = None
            elif line in ("app_diagnostics_v1", "network_probe_heartbeat_v1"):
                break
            elif section and line:
                if header is None:
                    header = line.split("\t")
                    continue
                values = dict(zip(header, line.split("\t")))
                if section == "rounds":
                    rounds.append({key: int(value) if value.isdecimal() else value
                                   for key, value in values.items()})
                else:
                    arrivals.append((int(values["received_at_ns"]),
                                     int(values["sequence"])))
    if not rounds:
        raise ValueError("report contains no network probe rounds")
    return stream_id, rounds, arrivals


def load_sender(path):
    packets = {}
    with path.open(encoding="utf-8") as source:
        for line in source:
            record = json.loads(line)
            if record.get("type") == "packet":
                packets[record["sequence"]] = record
    return packets


def load_sender_rounds(path, stream_id):
    summaries = {}
    if path is None:
        return summaries
    with path.open(encoding="utf-8", errors="replace") as source:
        for line in source:
            marker = "network_probe_round_end "
            if marker not in line:
                continue
            fields = dict(field.split("=", 1) for field in
                          line.split(marker, 1)[1].split() if "=" in field)
            if fields.get("stream_id") == str(stream_id):
                summaries[int(fields["round"])] = {
                    key: int(value) for key, value in fields.items()
                    if value.isdecimal() and key not in ("round", "stream_id")
                }
    return summaries


def simulate_buffer(arrivals_ns, rate, seconds, target_ms, adaptive):
    if not arrivals_ns:
        return None
    arrivals = sorted(arrivals_ns)
    first = arrivals[0]
    end = first + seconds * 1_000_000_000
    now = first + target_ms * 1_000_000
    interval = 1_000_000_000 / rate
    target_packets = rate * target_ms / 1_000
    index = 0
    fill = 0
    ticks = empty = episodes = peak = slow = fast = 0
    was_empty = False
    while now < end:
        while index < len(arrivals) and arrivals[index] <= now:
            index += 1
            fill += 1
        peak = max(peak, fill)
        if adaptive and fill < target_packets * 0.5:
            speed = 0.98
            slow += 1
        elif adaptive and fill > target_packets * 1.5:
            speed = 1.02
            fast += 1
        else:
            speed = 1.0
        if fill:
            fill -= 1
            was_empty = False
        else:
            empty += 1
            if not was_empty:
                episodes += 1
            was_empty = True
        ticks += 1
        now += interval / speed
    return {"ticks": ticks, "empty": empty, "episodes": episodes,
            "end_fill": fill, "peak_fill": peak, "slow_ticks": slow,
            "fast_ticks": fast}


def metric_summary(values):
    if not values:
        return None
    values = sorted(values)
    return {"p50": round(values[(len(values) - 1) // 2], 3),
            "p99": round(values[int((len(values) - 1) * .99)], 3),
            "max": round(values[-1], 3)}


def load_receiver_timing(path):
    packets, heartbeats = {}, []
    section = None
    with path.open(encoding="utf-8") as source:
        for raw in source:
            line = raw.rstrip("\n")
            if line in ("network_probe_trace_v2", "network_probe_heartbeat_v1"):
                section = line
                header = None
            elif line == "app_diagnostics_v1":
                break
            elif section and line:
                if header is None:
                    header = line.split("\t")
                    continue
                row = {key: int(value) for key, value in zip(header, line.split("\t"))}
                if section == "network_probe_trace_v2":
                    packets.setdefault(row["sequence"], row)
                else:
                    heartbeats.append(row)
    return packets, heartbeats


def load_transport_samples(path):
    if path is None:
        return []
    samples = []
    with path.open(encoding="utf-8", errors="replace") as source:
        for line in source:
            marker = "network_probe_transport "
            if marker in line:
                samples.append({key: int(value) for key, value in
                                (field.split("=", 1) for field in
                                 line.split(marker, 1)[1].split() if "=" in field)})
    return samples


def simulate_playout(arrivals, sender, start, planned, rate, target_ms, adaptive,
                     burst_packets=1):
    """Replay sequence positions using the fastest transit as a best-case clock offset."""
    matched = [sequence for sequence in arrivals if sequence in sender and
               "send_at_ns" in sender[sequence] and "captured_at_ns" in sender[sequence]]
    if not matched:
        return None
    interval = 1_000_000_000 / rate
    first = min(sequence for sequence, row in sender.items() if "captured_at_ns" in row)
    first_tick = (first - start) // burst_packets * burst_packets
    origin = sender[first]["captured_at_ns"] - first_tick * interval
    offset = min(arrivals[sequence] - sender[sequence]["send_at_ns"] for sequence in matched)
    now = origin + offset + target_ms * 1_000_000
    received = sorted((time, sequence) for sequence, time in arrivals.items())
    ready, index = set(), 0
    missing = late = played = peak = slow = fast = over_budget = 0
    delays = []
    target_packets = rate * target_ms / 1_000
    for sequence in range(start, start + planned):
        while index < len(received) and received[index][0] <= now:
            if received[index][1] >= sequence:
                ready.add(received[index][1])
            index += 1
        peak = max(peak, len(ready))
        speed = 1.0
        if adaptive and len(ready) < target_packets * .5:
            speed = .98
            slow += 1
        elif adaptive and len(ready) > target_packets * 1.5:
            speed = 1.02
            fast += 1
        delay = (now - (origin + offset + (sequence - start) * interval)) / 1_000_000
        delays.append(delay)
        over_budget += delay > target_ms + .001
        if sequence in ready:
            played += 1
            ready.remove(sequence)
        elif sequence in arrivals:
            late += 1
        else:
            missing += 1
        now += interval / speed
    return {"clock_alignment": "minimum_observed_transit_best_case",
            "played": played, "concealed_missing": missing, "concealed_late": late,
            "concealment_media_ms": round((missing + late) * 1_000 / rate, 3),
            "playout_delay_ms": metric_summary(delays),
            "delay_budget_exceeded_packets": over_budget,
            "peak_fill_packets": peak, "slow_ticks": slow, "fast_ticks": fast}


def analyze(report, sender, target_ms, sender_log=None):
    stream_id, rounds, arrivals = load_report(report)
    packets = load_sender(sender)
    if sender_log is None and (sender.parent / "sender.log").exists():
        sender_log = sender.parent / "sender.log"
    sender_rounds = load_sender_rounds(sender_log, stream_id)
    processing, heartbeats = load_receiver_timing(report)
    transport_samples = load_transport_samples(sender_log)
    clock_offsets = [time - packets[sequence]["send_at_ns"] for time, sequence in arrivals
                     if sequence in packets and "send_at_ns" in packets[sequence]]
    clock_offset = min(clock_offsets) if clock_offsets else None
    for round_info in rounds:
        start = round_info["first_sequence"]
        stop = start + round_info["planned"]
        first_arrival = {}
        for time, sequence in arrivals:
            if start <= sequence < stop:
                first_arrival[sequence] = min(time, first_arrival.get(sequence, time))
        received = set(first_arrival)
        times = sorted(first_arrival.values())
        sender_rows = {sequence: packets[sequence] for sequence in range(start, stop)
                       if sequence in packets}
        missing = set(range(start, stop)) - received
        rejected = sum(not row["send_accepted"] for row in sender_rows.values())
        rejected_missing = sum(not sender_rows[sequence]["send_accepted"]
                               for sequence in missing if sequence in sender_rows)
        states = Counter(sender_rows[sequence]["send_state"] for sequence in missing
                         if sequence in sender_rows and sender_rows[sequence]["send_accepted"])
        gaps_ms = [(b - a) / 1_000_000 for a, b in zip(times, times[1:])]
        fixed = simulate_buffer(times, round_info["packets_per_second"],
                                round_info["seconds"], target_ms, False)
        adaptive = simulate_buffer(times, round_info["packets_per_second"],
                                   round_info["seconds"], target_ms, True)
        timing_rows = [packets[sequence] for sequence in sender_rows
                       if "captured_at_ns" in packets[sequence]]
        round_samples = []
        round_heartbeats = heartbeats
        heartbeat_scope = "session_unaligned"
        if timing_rows:
            beginning = min(row["captured_at_ns"] for row in timing_rows)
            ending = beginning + round_info["seconds"] * 1_000_000_000
            round_samples = [row for row in transport_samples if beginning <= row["at_ns"] < ending]
            if clock_offset is not None:
                round_heartbeats = [row for row in heartbeats
                                   if row["at_ns"] >= beginning + clock_offset and
                                   row["scheduled_at_ns"] < ending + clock_offset]
                heartbeat_scope = "planned_round"
        transit = [(first_arrival[sequence] - row["send_at_ns"]) / 1_000_000
                   for sequence, row in sender_rows.items() if sequence in received and
                   "send_at_ns" in row]
        minimum_transit = min(transit) if transit else 0
        completion = [(row["send_completed_at_ns"] - row["send_at_ns"]) / 1_000_000
                      for row in sender_rows.values() if row.get("send_completed_at_ns", 0) and
                      not row.get("send_canceled", False)]
        processing_delays = [(processing[sequence]["recorded_at_ns"] -
                              processing[sequence]["received_at_ns"]) / 1_000_000
                             for sequence in received if sequence in processing]
        heartbeat_delays = [(row["at_ns"] - row["scheduled_at_ns"]) / 1_000_000
                            for row in round_heartbeats]
        yield {
            "round": round_info["round"], "transport": round_info["transport"],
            "repeat": round_info.get("repeat"),
            "variant": round_info.get("variant"),
            "payload_bytes": round_info["payload_bytes"],
            "packets_per_second": round_info["packets_per_second"],
            "burst_packets": round_info["burst_packets"],
            "planned": round_info["planned"], "received_unique": len(received),
            "sender_trace_missing": round_info["planned"] - len(sender_rows),
            "sender_rejected": rejected,
            "sender_rejection_reasons": dict(Counter(row.get("send_status", "unknown")
                for row in sender_rows.values() if not row["send_accepted"])),
            "sender_pending_peak": max((row.get("pending_reliable_sends", 0)
                                         for row in sender_rows.values()), default=0),
            "missing_after_sender_rejection": rejected_missing,
            "missing_after_accepted_by_send_state": dict(states),
            "max_receiver_gap_ms": round(max(gaps_ms), 2) if gaps_ms else None,
            "receiver_gaps_over_100_ms": sum(gap > 100 for gap in gaps_ms),
            "sender_round": sender_rounds.get(round_info["round"]),
            "sender_schedule_lateness_ms": metric_summary([
                (row["send_at_ns"] - row["captured_at_ns"]) / 1_000_000
                for row in timing_rows]),
            "relative_transit_extra_ms": metric_summary([value - minimum_transit
                                                         for value in transit]) if transit else None,
            "reliable_send_completion_ms": metric_summary(completion),
            "receiver_processing_ms": metric_summary(processing_delays),
            "receiver_heartbeat_lateness_ms": metric_summary(heartbeat_delays),
            "receiver_heartbeat_scope": heartbeat_scope,
            "transport_samples": round_samples,
            "fixed_buffer": fixed, "adaptive_buffer": adaptive,
            "fixed_playout": simulate_playout(first_arrival, sender_rows, start,
                round_info["planned"], round_info["packets_per_second"], target_ms, False,
                round_info["burst_packets"]),
            "adaptive_playout": simulate_playout(first_arrival, sender_rows, start,
                round_info["planned"], round_info["packets_per_second"], target_ms, True,
                round_info["burst_packets"]),
        }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("sender_trace", type=Path)
    parser.add_argument("--sender-log", type=Path,
                        help="optional HearPort-sender.log with send rejection reasons")
    parser.add_argument("--target-ms", type=int, default=100,
                        help="virtual startup and target buffer (default: 100 ms)")
    args = parser.parse_args()
    if args.target_ms <= 0:
        parser.error("--target-ms must be positive")
    for result in analyze(args.report, args.sender_trace, args.target_ms,
                          args.sender_log):
        print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
